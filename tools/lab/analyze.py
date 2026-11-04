#!/usr/bin/env python3
"""analyze.py <log.jsonl> — dựng lại dòng mà chương trình trong terminal nhận được (áp DEL/BS, bỏ escape) và đo
độ "nguyên khối": mỗi lần xoá có tới cùng một lần read() với chữ thay vào không (tách rời => shell có thể vẽ
trạng thái giữa chừng => nháy chữ)."""
import json
import re
import sys

ESC = re.compile(rb"\x1b\[[0-9;:<=>?]*[A-Za-z~]|\x1b[O][A-Za-z]")


def analyze(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    chunks = [(r["t"], bytes.fromhex(r["hex"])) for r in rows if "hex" in r]
    line, edits, split = [], 0, 0
    escapes = []
    for i, (t, b) in enumerate(chunks):
        escapes += [m.decode("latin-1") for m in ESC.findall(b)]
        s = ESC.sub(b"", b).decode("utf-8", "replace")
        if "\x7f" in s or "\x08" in s:
            edits += 1
            rest = s.replace("\x7f", "").replace("\x08", "")
            nxt = chunks[i + 1] if i + 1 < len(chunks) else None
            if not rest and nxt and nxt[0] - t < 0.25 and b"\x7f" not in nxt[1] and b"\x08" not in nxt[1]:
                split += 1
        for ch in s:
            if ch in "\x7f\x08":
                if line:
                    line.pop()
            elif ch == "\x15":
                line.clear()
            elif ch >= " ":
                line.append(ch)
    return {
        "final": "".join(line),
        "chunks": len(chunks),
        "edits": edits,
        "edits_split": split,
        "escapes": escapes[:20],
        "raw": [c.decode("utf-8", "backslashreplace") for _, c in chunks][:400],
    }


if __name__ == "__main__":
    print(json.dumps(analyze(sys.argv[1]), ensure_ascii=False, indent=1))
