#!/usr/bin/env python3
"""IME Lab — dò xem phím giả kiểu nào đi qua bộ gõ (GTV ghi "phím …" vào GTV-debug.log khi nhận được).
Mở Terminal chạy capture.py, gõ "a6 " (VNI: "á"? không — "a6" -> "â") bằng nhiều cách tạo phím."""
import json, os, pathlib, shutil, subprocess, sys, time
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from analyze import analyze  # noqa: E402

# tools/lab/lab.env (nếu có) ghi đè TERMS/METHODS/STYLES — để chạy lab bằng push mà không cần input.
_cfg = pathlib.Path(__file__).resolve().parent / "lab.env"
if _cfg.exists():
    for _line in _cfg.read_text().splitlines():
        if "=" in _line and not _line.lstrip().startswith("#"):
            _k, _v = _line.split("=", 1)
            os.environ[_k.strip()] = _v.strip()
L = pathlib.Path("/tmp/l"); OUT = pathlib.Path(os.environ.get("OUT", "lab-out")).resolve()
LOG = pathlib.Path.home() / "Library/Logs/GTV-debug.log"
BID = "com.apple.Terminal"

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=kw.get("timeout", 60), env=kw.get("env"))

def keylines():
    """Số phím GTV nhận ở Terminal (dòng "phím <mã> '<ký tự>' <app>: …", không tính dòng "sổ phím")."""
    if not LOG.exists():
        return 0
    return sum(1 for l in LOG.read_text(errors="replace").splitlines() if " phím " in l and BID in l)

VARIANTS = [
    ("hid+unicode", {"DRIVER_UNICODE": "1"}),
    ("hid-nounicode", {"DRIVER_UNICODE": "0"}),
    ("session-combined", {"DRIVER_TAP": "session", "DRIVER_SOURCE": "combined", "DRIVER_UNICODE": "0"}),
    ("annotated-private", {"DRIVER_TAP": "annotated", "DRIVER_SOURCE": "private", "DRIVER_UNICODE": "0"}),
    ("hid-kbtype40", {"DRIVER_UNICODE": "0", "DRIVER_KBTYPE": "40"}),
    ("osascript", None),
]

def e_mode_probe():
    """Terminal.app: ở chế độ E (GTV.en) phím có còn tới GTV không, theo từng cách đổi chế độ (lab 41871623817: chọn
    GTV.en bằng TISSelectInputSource thì GTV không thấy phím nào, kể cả ⌘⇧ để đổi lại)."""
    def terminal_keys():
        return sum(1 for l in LOG.read_text(errors="replace").splitlines() if " phím " in l and BID in l) if LOG.exists() else 0
    rows = []
    steps = [("e-tis", "{IS:en}", "x"), ("v-tis", "{IS:vi}", "a"), ("e-toggle", "{TOGGLE}", "y"),
             ("v-toggle", "{TOGGLE}", "b"), ("e-tis-new-window", "{IS:en}{CMDN}{WAIT1500}", "z"),
             ("v-tis-new-window", "{IS:vi}", "c")]
    for name, switch, key in steps:
        sh([str(L / "drv"), BID, "40", switch]); time.sleep(0.8)
        before = terminal_keys()
        sh([str(L / "drv"), BID, "60", key]); time.sleep(0.6)
        source = sh([str(L / "is"), "get"]).stdout.strip()
        rows.append({"variant": name, "gtv_saw_keys": terminal_keys() - before, "shell_got": source, "err": ""})
        print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
    sh([str(L / "drv"), BID, "30", "{IS:en}{CU}"])
    return rows


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    shutil.copy(HERE / "capture.py", L / "c.py")
    sh(["defaults", "write", "com.gtv.inputmethod.GTV", "method", "-int", "1"])
    sh(["defaults", "write", "com.gtv.inputmethod.GTV", "terminalStyle", "-string", "inline"])
    sh(["notifyutil", "-p", "com.gtv.lab.reload"])
    sh(["open", "-a", "/System/Applications/Utilities/Terminal.app"]); time.sleep(4)
    rows = []
    for name, env in VARIANTS:
        log = L / f"probe-{name}.jsonl"; log.unlink(missing_ok=True)
        sh([str(L / "drv"), BID, "15", f"{{IS:en}}python3 /tmp/l/c.py {log} legacy{{RET}}"])
        for _ in range(80):
            if log.exists() and "ready" in log.read_text(): break
            time.sleep(0.1)
        sh([str(L / "drv"), BID, "40", "{IS:vi}"])
        before = keylines()
        if env is None:
            r = sh(["osascript", "-e", 'tell application "System Events" to keystroke "a6 "'])
            err = r.stderr.strip()
        else:
            e = dict(os.environ); e.update(env)
            r = sh([str(L / "drv"), BID, "60", "a6 "], env=e)
            err = r.stderr.strip()
        time.sleep(0.8)
        after = keylines()
        sh(["screencapture", "-x", str(OUT / f"probe-{name}.png")])
        sh([str(L / "drv"), BID, "30", "{IS:en}{CQ}"]); time.sleep(0.5)
        a = analyze(log) if log.exists() else {"final": None}
        rows.append({"variant": name, "gtv_saw_keys": after - before, "shell_got": a.get("final"), "err": err})
        print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
    rows += e_mode_probe()
    (OUT / "probe.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    md = "| cách tạo phím | GTV nhận | shell nhận | lỗi |\n|---|---|---|---|\n" + "\n".join(
        f"| {r['variant']} | {r['gtv_saw_keys']} | `{r['shell_got']}` | {r['err'][:80]} |" for r in rows)
    (OUT / "probe.md").write_text(md + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write("## Probe\n\n" + md + "\n")
    print(md)

if __name__ == "__main__":
    main()
