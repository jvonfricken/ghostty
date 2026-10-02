//! HostManaged is a termio backend with no process and no pty: the embedder
//! (the "host") owns the transport. Bytes the program on the other end wrote
//! are pushed in with `ghostty_surface_write_buffer`; bytes the terminal wants
//! to send (keyboard input, query replies) leave through the `write`
//! callback; grid size changes leave through the `resize` callback.
//!
//! The C API shape follows libghostty-spm's host-managed IO patch
//! (https://github.com/Lakr233/libghostty-spm, MIT, by @Lakr233) so a host
//! written against either can move to the other. The CR to CRLF handling in
//! linefeed mode follows VVTerm's callback backend
//! (https://github.com/wiedymi/ghostty, src/termio/Callback.zig, MIT, by
//! Wiedy Mi).
const HostManaged = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_host_managed);

userdata: ?*anyopaque = null,
write: Config.Write,
resize_cb: ?Config.Resize = null,
grid_size: renderer.GridSize = .{ .columns = 0, .rows = 0 },
screen_size: renderer.ScreenSize = .{ .width = 0, .height = 0 },

/// The last size given to the resize callback, so a resize to the size the
/// host already has (the first one after the thread starts, usually) is not
/// reported twice.
reported: ?[4]u32 = null,

pub const Config = struct {
    /// Called on the termio thread with bytes the terminal emits.
    pub const Write = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;

    /// Called on the termio thread with (columns, rows, width_px, height_px)
    /// whenever the grid size changes, and once when the thread starts.
    pub const Resize = *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void;

    userdata: ?*anyopaque = null,
    write: Write,
    resize: ?Resize = null,
};

pub fn init(cfg: Config) HostManaged {
    return .{
        .userdata = cfg.userdata,
        .write = cfg.write,
        .resize_cb = cfg.resize,
    };
}

pub fn deinit(self: *HostManaged) void {
    _ = self;
}

pub fn initTerminal(self: *HostManaged, term: *terminal.Terminal) void {
    self.grid_size = .{ .columns = term.cols, .rows = term.rows };
    self.screen_size = .{ .width = term.width_px, .height = term.height_px };
}

pub fn threadEnter(
    self: *HostManaged,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    _ = io;
    td.backend = .{ .host_managed = .{} };
    self.notifyResize();
}

pub fn threadExit(self: *HostManaged, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *HostManaged,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *HostManaged,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;
    self.notifyResize();
}

pub fn queueWrite(
    self: *HostManaged,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    writeTo(self.write, self.userdata, data, linefeed);
}

fn writeTo(
    write: Config.Write,
    userdata: ?*anyopaque,
    data: []const u8,
    linefeed: bool,
) void {
    if (data.len == 0) return;
    if (!linefeed) {
        write(userdata, data.ptr, data.len);
        return;
    }

    // Linefeed mode (LNM): every CR the terminal sends becomes CRLF, as the
    // exec backend does before writing to the pty.
    var i: usize = 0;
    while (i < data.len) {
        const j = std.mem.indexOfScalarPos(u8, data, i, '\r') orelse data.len;
        if (j > i) write(userdata, data.ptr + i, j - i);
        if (j < data.len) {
            const crlf = "\r\n";
            write(userdata, crlf.ptr, crlf.len);
        }
        i = j + 1;
    }
}

pub fn childExitedAbnormally(
    self: *HostManaged,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

fn notifyResize(self: *HostManaged) void {
    const cb = self.resize_cb orelse return;
    const now: [4]u32 = .{
        self.grid_size.columns,
        self.grid_size.rows,
        self.screen_size.width,
        self.screen_size.height,
    };
    if (self.reported) |last| if (std.mem.eql(u32, &last, &now)) return;
    self.reported = now;
    cb(
        self.userdata,
        self.grid_size.columns,
        self.grid_size.rows,
        self.screen_size.width,
        self.screen_size.height,
    );
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

const TestWriter = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn write(ud: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestWriter = @ptrCast(@alignCast(ud.?));
        @memcpy(self.buf[self.len..][0..len], data[0..len]);
        self.len += len;
    }

    fn bytes(self: *const TestWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

test "host managed: bytes pass through unchanged" {
    var w: TestWriter = .{};
    writeTo(TestWriter.write, &w, "a\rb", false);
    try std.testing.expectEqualStrings("a\rb", w.bytes());
}

test "host managed: linefeed mode turns CR into CRLF" {
    var w: TestWriter = .{};
    writeTo(TestWriter.write, &w, "a\rb\r\r", true);
    try std.testing.expectEqualStrings("a\r\nb\r\n\r\n", w.bytes());
}
