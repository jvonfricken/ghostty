libxev at 34fa50878aec6e5fa8f532867001ab3c36fae23e (the commit Ghostty 1.3.1
pins in build.zig.zon), vendored with one change: upstream libxev commit
7bf2b2f "fix(kqueue): support iOS mach_port operations" by Erik Langille
(mitchellh/libxev#204, MIT). Without it the kqueue backend registers mach-port
waits only on macOS, so on iOS every xev.Async wakeup is lost and Ghostty's io
and renderer threads never wake. The change is `== .macos` to `isDarwin()` in
two comptime checks; code compiled for macOS is unchanged.

Only build.zig, build.zig.zon, LICENSE, docs/ and examples/ (its build.zig
reads both), include/ and src/ are kept.
Drop this directory once Ghostty pins a libxev that includes 7bf2b2f.
