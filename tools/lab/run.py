#!/usr/bin/env python3
"""IME Lab — chạy trên runner macOS của GitHub Actions (máy ảo dùng một lần, không bao giờ trên máy thật).

Với từng terminal: mở ứng dụng, gõ phím giả qua HID (đi qua bộ gõ GTV như bàn phím thật), rồi
- capture: chương trình trong terminal ghi lại từng byte nhận được -> dòng cuối cùng + độ nguyên khối của mỗi lần xoá;
- fish:    gõ vào fish thật rồi đọc dòng lệnh (commandline) -> kiểm tra gợi ý lệnh / Ctrl+E.
Mỗi bài chụp màn hình. Kết quả: $OUT/results.json, $OUT/summary.md (+ $GITHUB_STEP_SUMMARY).

Biến môi trường: TERMS="terminal iterm2 ghostty kitty wezterm rex", METHODS="vni telex",
STYLES="marked inline deferred direct" (cách gõ trong terminal, xem Settings.terminalMode), OUT=lab-out
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

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

L = pathlib.Path("/tmp/l")
OUT = pathlib.Path(os.environ.get("OUT", "lab-out")).resolve()
DRV = str(L / "drv")
IM = pathlib.Path.home() / "Library/Input Methods/GTVInput.app"

TERMINALS = {
    "terminal": ("com.apple.Terminal", "/System/Applications/Utilities/Terminal.app"),
    "iterm2": ("com.googlecode.iterm2", "/Applications/iTerm.app"),
    "ghostty": ("com.mitchellh.ghostty", "/Applications/Ghostty.app"),
    "kitty": ("net.kovidgoyal.kitty", "/Applications/kitty.app"),
    "wezterm": ("com.github.wez.wezterm", "/Applications/WezTerm.app"),
    "rex": ("com.superlogical.rex", "/Applications/Rex Beta.app"),
}

# (tên, kiểu gõ, phím, mong đợi, ms giữa 2 phím)
TERMINAL_IDS = ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty",
                "com.github.wez.wezterm", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.superlogical.rex",
                "com.muxy.app"]

CAPTURE = [
    ("vni-words", "vni", "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c.", "Việt Nam, tôi yêu tiếng Việt đại học.", 45),
    ("vni-fast", "vni", "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c.", "Việt Nam, tôi yêu tiếng Việt đại học.", 12),
    ("vni-backspace", "vni", "tie61ng{BS}{BS}{BS}e65t ", "tiệt ", 45),
    ("telex-words", "telex", "Vieetj Nam, tooi yeeu tieengs Vieetj ddaij hocj.", "Việt Nam, tôi yêu tiếng Việt đại học.", 45),
]
# Phím đặc biệt có tới bộ gõ không (khi không có marked text) — xem GTV-debug.log, dòng "phím <mã>".
KEYS_SEEN = "ab{LEFT}{RIGHT}{BS}{TAB}{CE}{CA}{UP}{DOWN}c"

FISH = [
    # Lỗi người dùng báo: gõ ./suo rồi Ctrl+E phải nhận gợi ý của fish.
    ("fish-ctrl-e", "vni", "./suo{WAIT400}{CE}", "./suoddms-quickstart-6.0.23.tar/", 45),
    ("fish-vietnamese", "vni", "echo Vie65t Nam d9a5i ho5c", "echo Việt Nam đại học", 45),
]


def sh(cmd, timeout=60, check=False):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f"{cmd}: {r.stderr.strip()}")
    return r


def front():
    asn = sh(["lsappinfo", "front"]).stdout.strip()
    out = sh(["lsappinfo", "info", "-only", "bundleid", asn]).stdout
    return out.split("=", 1)[1].strip().strip('"') if "=" in out else ""


def drv(bid, keys, ms=45, timeout=120):
    r = sh([DRV, bid, str(ms), keys], timeout=timeout)
    if r.returncode:
        raise RuntimeError(f"driver lỗi {r.returncode}: {r.stderr.strip() or r.stdout.strip()}")


def shot(name):
    p = OUT / "shots" / f"{name}.png"
    p.parent.mkdir(parents=True, exist_ok=True)
    sh(["screencapture", "-x", str(p)])
    return str(p.relative_to(OUT))


def current_source():
    return sh([str(L / "is"), "get"]).stdout.strip()


def configure(method, style):
    """Đổi kiểu gõ / cách gõ trong terminal mà không tắt bộ gõ (bản Debug nghe com.gtv.lab.reload)."""
    d = "com.gtv.inputmethod.GTV"
    sh(["defaults", "write", d, "method", "-int", "1" if method == "vni" else "0"])
    sh(["defaults", "write", d, "terminalStyle", "-string", style])
    sh(["defaults", "write", d, "markedApps", "-array", *TERMINAL_IDS])
    sh(["notifyutil", "-p", "com.gtv.lab.reload"])
    time.sleep(0.4)


def dismiss_dialogs():
    """Hộp thoại hệ thống (vd. iTerm2 xin quyền mạng nội bộ) chiếm phía trước: bấm Esc (= Không cho phép)."""
    for _ in range(5):
        if front() not in ("com.apple.UserNotificationCenter", "com.apple.UserNotificationCenterAgent"):
            return
        sh([DRV, "-", "10", "{ESC}"])
        time.sleep(0.8)


def open_terminal(key):
    bid, path = TERMINALS[key]
    dismiss_dialogs()
    sh(["open", "-a", path])
    for _ in range(150):
        if front() == bid:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError(f"{key} không lên phía trước (front={front()})")
    time.sleep(3)          # đợi shell sẵn sàng
    if key == "rex":       # màn hình chào lần đầu: bấm Continue rồi mở cửa sổ terminal mới
        for _ in range(6):
            sh([DRV, bid, "10", "{RET}"]); time.sleep(0.6)
        sh([DRV, bid, "10", "{CMDN}"]); time.sleep(2.5)
        shot("rex-after-onboarding")
    dismiss_dialogs()
    if front() != bid:
        sh(["open", "-a", path])
        time.sleep(1)
    return bid


def close_terminal(key):
    _, path = TERMINALS[key]
    sh(["pkill", "-f", f"{path}/Contents/MacOS/"])
    time.sleep(1.5)


def run_capture(key, bid, name, method, keys, expect, ms):
    dismiss_dialogs()
    log = L / f"{key}-{name}.jsonl"
    log.unlink(missing_ok=True)
    drv(bid, f"{{IS:en}}python3 /tmp/l/c.py {log} legacy{{RET}}", 15)
    for _ in range(100):
        if log.exists() and "ready" in log.read_text():
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("capture.py không chạy")
    drv(bid, "{IS:vi}" + keys, ms)
    time.sleep(0.6)
    img = shot(f"{key}-{name}")
    source = current_source()
    drv(bid, "{IS:en}{CQ}", 30)
    time.sleep(0.4)
    shutil.copy(log, OUT / "logs" / log.name)
    a = analyze(log)
    return {"final": a["final"], "pass": a["final"] == expect, "chunks": a["chunks"], "edits": a["edits"],
            "edits_split": a["edits_split"], "escapes": a["escapes"], "raw": a["raw"], "shot": img, "source": source}


def run_fish(key, bid, name, method, keys, expect, ms):
    dismiss_dialogs()
    out = L / f"{key}-{name}.txt"
    out.unlink(missing_ok=True)
    drv(bid, f"{{IS:en}}cd /tmp/l/fd && fish -N -C \"bind ctrl-x 'commandline > {out}'\"{{RET}}", 15)
    time.sleep(3)
    drv(bid, "{IS:vi}" + keys, ms)
    time.sleep(0.8)
    img = shot(f"{key}-{name}")
    source = current_source()
    drv(bid, "{CX}", 40)
    time.sleep(0.8)
    final = out.read_text().rstrip("\n") if out.exists() else None
    drv(bid, "{CU}{IS:en}exit{RET}", 30)
    time.sleep(0.8)
    return {"final": final, "pass": final == expect, "shot": img, "source": source}


def main():
    (OUT / "logs").mkdir(parents=True, exist_ok=True)
    (L / "fd" / "suoddms-quickstart-6.0.23.tar").mkdir(parents=True, exist_ok=True)
    shutil.copy(HERE / "capture.py", L / "c.py")
    terms = os.environ.get("TERMS", "terminal ghostty kitty wezterm rex iterm2").split()
    methods = os.environ.get("METHODS", "vni telex").split()
    styles = os.environ.get("STYLES", "marked inline deferred direct").split()
    results = []
    for key in terms:
        if key not in TERMINALS or not pathlib.Path(TERMINALS[key][1]).exists():
            results.append({"terminal": key, "test": "-", "error": "chưa cài"})
            continue
        bid = None
        try:
            bid = open_terminal(key)
            shot(f"{key}-opened")
            for style in styles:
                for method in methods:
                    configure(method, style)
                    tests = [("capture", t) for t in CAPTURE if t[1] == method]
                    if method == "vni":
                        tests.append(("capture", ("keys-seen", "vni", KEYS_SEEN, None, 120)))
                    if shutil.which("fish"):
                        tests += [("fish", t) for t in FISH if t[1] == method]
                    for kind, (name, m, keys, expect, ms) in tests:
                        label = f"{style}/{name}"
                        r = {"terminal": key, "style": style, "test": name, "expect": expect}
                        try:
                            run = run_capture if kind == "capture" else run_fish
                            r.update(run(key, bid, f"{style}-{name}", method, keys, expect, ms))
                        except Exception as e:  # noqa: BLE001
                            r["error"] = str(e)
                            shot(f"{key}-{style}-{name}-error")
                        results.append(r)
                        print(label, json.dumps({k: v for k, v in r.items() if k != "raw"}, ensure_ascii=False), flush=True)
        except Exception as e:  # noqa: BLE001
            results.append({"terminal": key, "test": "-", "error": str(e)})
            shot(f"{key}-fatal")
        finally:
            close_terminal(key)

    (OUT / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1))
    rows = ["| terminal | kiểu | bài | kết quả | shell nhận | xoá tách rời | ghi chú |", "|---|---|---|---|---|---|---|"]
    for r in results:
        ok = "lỗi" if "error" in r else ("✅" if r.get("pass") else "❌")
        split = f"{r.get('edits_split', '')}/{r.get('edits', '')}" if "edits" in r else ""
        note = r.get("error", "") or ("mong đợi: " + r["expect"] if not r.get("pass") and "expect" in r else "")
        rows.append(f"| {r['terminal']} | {r.get('style', '')} | {r['test']} | {ok} | `{r.get('final', '')}` | {split} | {note} |")
    md = "\n".join(rows)
    (OUT / "summary.md").write_text(md + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## IME Lab\n\n" + md + "\n")
    print(md)


if __name__ == "__main__":
    main()
