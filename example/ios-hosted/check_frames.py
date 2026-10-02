#!/usr/bin/env python3
"""Asserts on what the fake server received from the demo's scenario."""
import json, sys

frames = [json.loads(l) for l in open(sys.argv[1])]
binary = b"".join(bytes.fromhex(f["hex"]) for f in frames if f["kind"] == "binary")
texts = [f["json"] for f in frames if f["kind"] == "text"]
ok = True

def check(name, cond):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name)

opening = texts[0] if texts else {}
check(f"opened at the view's size, not 800x600 ({opening.get('columns')}x{opening.get('rows')})",
      opening.get("columns", 0) > 30 and opening.get("rows", 0) > 20)
check("typed text arrived as UTF-8", "echo héllo ✓".encode() in binary)
check("backspace sent DEL (0x7f)", b"\xe2\x9c\x93\x7f" in binary)
check("return sent CR", b"ok\r" in binary)
check("ctrl-c sent ETX (0x03)", b"\x03" in binary)
check("arrow up sent ESC [ A", b"\x1b[A" in binary)
check("ghostty answered DA1 itself", b"\x1b[?62;22;52c" in binary)
resizes = [t["resize"] for t in texts if "resize" in t]
check(f"resize frame sent after the view shrank ({resizes})",
      resizes and resizes[-1]["rows"] < opening.get("rows", 0))
check("no duplicate resize frames",
      all(a != b for a, b in zip([opening and {"cols": opening["columns"], "rows": opening["rows"]}] + resizes, resizes)))
sys.exit(0 if ok else 1)
