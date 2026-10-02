#!/usr/bin/env python3
"""A stand-in for a terminal host speaking Infinite's /terminal framing.

Binary frames carry terminal bytes both ways. Text frames are JSON control:
the client opens with {"columns", "rows", ...}, resizes with
{"resize": {"cols", "rows"}}; the server ends with {"exit": {"code"}}.

The "program" on this end is a scripted fake shell: it paints a coloured
directory listing and a box-drawing panel, then echoes what it receives like a
line-discipline in cooked mode, answers a line with what it got, and repaints
a status line on every resize. Every frame received is appended to the JSON
log given with --log, so a test can assert on exactly what the terminal sent.

No dependencies beyond the standard library (RFC 6455, server side, no
extensions, no fragmentation on send).
"""
import argparse, asyncio, base64, hashlib, json, os, struct, sys, time

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ESC = "\x1b"

def sgr(*codes):
    return f"{ESC}[{';'.join(str(c) for c in codes)}m"

def listing():
    rows = [
        ("drwxr-xr-x", "josh", "4.0K", "Oct  1 19:40", sgr(1, 34) + "Sources" + sgr(0) + "/"),
        ("drwxr-xr-x", "josh", "4.0K", "Oct  1 19:12", sgr(1, 34) + "Vendor" + sgr(0) + "/"),
        ("-rwxr-xr-x", "josh", " 812", "Sep 27 23:46", sgr(1, 32) + "build-ghosttykit.sh" + sgr(0) + "*"),
        ("-rw-r--r--", "josh", "3.1K", "Sep 30 08:02", "Package.swift"),
        ("lrwxr-xr-x", "josh", "  21", "Oct  1 09:20", sgr(1, 36) + "latest" + sgr(0) + " -> build/arm64"),
        ("-rw-r--r--", "josh", " 18M", "Oct  1 19:49", sgr(31) + "ghostty.tar.xz" + sgr(0)),
    ]
    out = sgr(1, 32) + "josh@box" + sgr(0) + ":" + sgr(1, 34) + "~/infinite" + sgr(0) + "$ ls -l\r\n"
    for perm, user, size, date, name in rows:
        out += f"{perm} {user} {size} {date} {name}\r\n"
    return out

def panel(cols):
    w = max(20, min(cols, 44))
    inner = w - 2
    def line(text, colour=None):
        body = text[:inner].ljust(inner)
        if colour:
            body = sgr(*colour) + body + sgr(0)
        return "│" + body + "│\r\n"
    out = "┌" + "─" * (inner - 8) + " status ┐\r\n"
    out += line(" ● api        running", (32,))
    out += line(" ● web        running", (32,))
    out += line(" ▲ worker     degraded", (33,))
    out += line(" ✗ migrations failed", (1, 31))
    out += "├" + "─" * inner + "┤\r\n"
    bar = int((inner - 12) * 0.62)
    out += line(" cpu " + "█" * bar + "░" * (inner - 12 - bar) + " 62%")
    out += "└" + "─" * inner + "┘\r\n"
    # A 256-colour strip below the panel.
    strip = "".join(f"{ESC}[48;5;{c}m " for c in range(16, 16 + min(36, cols - 1))) + sgr(0)
    out += strip + "\r\n"
    # Font fallback: CJK, emoji and symbols are not in the built-in font.
    out += "fallback: λ ≠ ∞ 日本語 한국어 🚀✨ " + sgr(3) + "italic" + sgr(0) + " " + sgr(4) + "underline" + sgr(0) + "\r\n"
    return out

PROMPT = sgr(1, 32) + "josh@box" + sgr(0) + ":" + sgr(1, 34) + "~/infinite" + sgr(0) + "$ "

class Conn:
    def __init__(self, reader, writer, log):
        self.r, self.w, self.log = reader, writer, log
        self.cols, self.rows = 80, 24
        self.line = b""

    def record(self, kind, payload):
        with open(self.log, "a") as f:
            f.write(json.dumps({"t": time.time(), "kind": kind, **payload}) + "\n")

    async def handshake(self):
        req = await self.r.readuntil(b"\r\n\r\n")
        headers = {}
        for l in req.decode().split("\r\n")[1:]:
            if ":" in l:
                k, v = l.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        key = headers["sec-websocket-key"].encode()
        acc = base64.b64encode(hashlib.sha1(key + GUID).digest()).decode()
        self.w.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                      "Connection: Upgrade\r\nSec-WebSocket-Accept: " + acc + "\r\n\r\n").encode())
        await self.w.drain()

    async def read_frame(self):
        h = await self.r.readexactly(2)
        op, ln = h[0] & 0x0F, h[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", await self.r.readexactly(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", await self.r.readexactly(8))[0]
        mask = await self.r.readexactly(4) if h[1] & 0x80 else b"\0\0\0\0"
        data = bytearray(await self.r.readexactly(ln))
        for i in range(ln):
            data[i] ^= mask[i % 4]
        return op, bytes(data)

    def send(self, op, data):
        hdr = bytes([0x80 | op])
        n = len(data)
        if n < 126:
            hdr += bytes([n])
        elif n < 65536:
            hdr += bytes([126]) + struct.pack(">H", n)
        else:
            hdr += bytes([127]) + struct.pack(">Q", n)
        self.w.write(hdr + data)

    def out(self, s):
        self.send(0x2, s.encode() if isinstance(s, str) else s)

    def status(self):
        # Save cursor, paint the bottom line in reverse video, restore.
        text = f" fake host · {self.cols}x{self.rows} · resizes seen: {self.resizes} "
        return (f"{ESC}7{ESC}[{self.rows};1H{ESC}[7m" + text[: self.cols].ljust(self.cols)
                + f"{ESC}[0m{ESC}8")

    async def run(self):
        await self.handshake()
        self.resizes = 0
        opened = False
        while True:
            try:
                op, data = await self.read_frame()
            except (asyncio.IncompleteReadError, ConnectionError):
                break
            if op == 0x8:
                self.record("close", {})
                break
            if op == 0x9:
                self.send(0xA, data); continue
            if op == 0x1:
                msg = json.loads(data)
                self.record("text", {"json": msg})
                if not opened and "columns" in msg:
                    opened = True
                    self.cols, self.rows = msg["columns"], msg["rows"]
                    self.out(listing())
                    self.out(panel(self.cols))
                    self.out(self.status())
                    self.out(PROMPT)
                elif "resize" in msg:
                    self.resizes += 1
                    self.cols, self.rows = msg["resize"]["cols"], msg["resize"]["rows"]
                    self.out(self.status())
            elif op == 0x2:
                self.record("binary", {"hex": data.hex(), "text": data.decode("utf-8", "replace")})
                await self.shell(data)
            await self.w.drain()
        self.w.close()

    async def shell(self, data):
        for b in data:
            c = bytes([b])
            if c == b"\r":
                cmd = self.line.decode("utf-8", "replace")
                self.line = b""
                self.out("\r\n")
                if cmd:
                    self.out(sgr(36) + f"fake host got {len(cmd)} chars: " + sgr(0) + cmd + "\r\n")
                self.out(PROMPT)
            elif c == b"\x7f":
                if self.line:
                    # Drop one character (not one byte) and erase it.
                    self.line = self.line.decode("utf-8", "replace")[:-1].encode()
                    self.out("\b \b")
            elif c == b"\x03":
                self.line = b""
                self.out("^C\r\n" + PROMPT)
            elif c == b"\x1b":
                self.out(sgr(2) + "<esc>" + sgr(0))
            elif b >= 0x20:
                self.line += c
                self.out(c)

async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--log", default="frames.jsonl")
    a = ap.parse_args()
    open(a.log, "w").close()

    async def handle(r, w):
        await Conn(r, w, a.log).run()

    server = await asyncio.start_server(handle, "127.0.0.1", a.port)
    print(f"listening on ws://127.0.0.1:{a.port}/terminal, logging to {a.log}", flush=True)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    asyncio.run(main())
