#!/usr/bin/env python3
"""Chạy trong terminal: ghi mọi byte terminal gửi xuống (raw mode) kèm thời điểm, mỗi lần read() một dòng.
capture.py <log> [legacy|kitty]   — kitty: bật kitty keyboard protocol (flag 1) như fish 4.
Thoát: Ctrl+\\ ."""
import os, sys, tty, termios, time, json, select
log, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "legacy")
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
out = open(log, "w", buffering=1)
if mode == "kitty":
    os.write(1, b"\x1b[>1u")
os.write(1, ("CAPTURE " + mode + " READY\r\n").encode())
out.write(json.dumps({"t": time.monotonic(), "ready": True, "mode": mode}) + "\n")
try:
    while True:
        r, _, _ = select.select([fd], [], [], 900)
        if not r:
            break
        data = os.read(fd, 4096)
        out.write(json.dumps({"t": time.monotonic(), "hex": data.hex()}) + "\n")
        if b"\x1c" in data:
            break
        os.write(1, data.replace(b"\x7f", b"\b \b").replace(b"\r", b"\r\n"))
finally:
    if mode == "kitty":
        os.write(1, b"\x1b[<u")
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
