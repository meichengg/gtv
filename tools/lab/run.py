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
    "muxy": ("com.muxy.app", "/Applications/Muxy.app"),
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
    # ⌘V giữa từ: phím đi vòng bộ gõ (sổ phím phải thấy), chữ dán không được bị xoá. Bộ nhớ tạm: PASTE.
    ("vni-paste", "vni", "tie{CMDV}{WAIT300}6 to6i", "tie/tmp6 tôi", 45),
]
PASTE = "/tmp"
# Phím đặc biệt có tới bộ gõ không (khi không có marked text) — xem GTV-debug.log, dòng "phím <mã>".
KEYS_SEEN = "ab{LEFT}{RIGHT}{BS}{TAB}{CE}{CA}{UP}{DOWN}{ESC}{CW}c"

FISH = [
    # Lỗi người dùng báo: gõ ./suo rồi Ctrl+E phải nhận gợi ý của fish.
    # Mỗi bài có một từ tiếng Việt làm đối chứng: GTV không xử lý phím thì bài không thể PASS.
    ("fish-ctrl-e", "vni", "echo vie65t ./suo{WAIT400}{CE}", "echo việt ./suoddms-quickstart-6.0.23.tar/", 45),
    ("fish-vietnamese", "vni", "echo Vie65t Nam d9a5i ho5c", "echo Việt Nam đại học", 45),
    # Phím terminal có thể tự xử lý không qua bộ gõ: không được xoá nhầm, gõ tiếp vẫn đúng.
    ("fish-arrow", "vni", "echo vie65t tie{LEFT}{WAIT300}6", "echo việt ti6e", 45),
    ("fish-backspace", "vni", "echo tie61ng{BS}{BS}{BS}{WAIT300}e65t", "echo tiệt", 45),
    ("fish-ctrl-a", "vni", "echo vie65t tie{CA}{WAIT300}6", "6echo việt tie", 45),
    ("fish-paste", "vni", "echo vie65t tie{CMDV}{WAIT300}6 to6i", "echo việt tie/tmp6 tôi", 45),
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


def ensure_mode(bid, target):
    """Đưa GTV về chế độ `target` ("vi"/"en"). LAB_SWITCH=hotkey: bấm ⌘⇧ như người dùng (mặc định);
    =tis: chọn input source bằng TISSelectInputSource từ tiến trình khác."""
    # Terminal.app: ở chế độ E phím (kể cả ⌘⇧) có lúc không tới bộ gõ (lab 41871623817) — chọn thẳng input source.
    if os.environ.get("LAB_SWITCH", "hotkey") == "tis" or bid == "com.apple.Terminal":
        drv(bid, "{IS:" + target + "}", 20)
        return
    for _ in range(3):
        if current_source().endswith("." + target):
            return
        drv(bid, "{TOGGLE}", 20)
        time.sleep(0.3)


def configure(method, style, delay=None):
    """Đổi kiểu gõ / cách gõ trong terminal mà không tắt bộ gõ (bản Debug nghe com.gtv.lab.reload).
    `delay`: thời gian chờ (ms) trước khi gửi lần sửa của kiểu deferred (Ghostty); None = mặc định của GTV."""
    d = "com.gtv.inputmethod.GTV"
    sh(["defaults", "write", d, "method", "-int", "1" if method == "vni" else "0"])
    sh(["defaults", "write", d, "terminalStyle", "-string", style])
    sh(["defaults", "write", d, "markedApps", "-array", *TERMINAL_IDS])
    if delay is None:
        sh(["defaults", "delete", d, "deferDelayMs"])
    else:
        sh(["defaults", "write", d, "deferDelayMs", "-float", str(delay)])
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
    if key == "muxy":      # cửa sổ dự án "No tabs": mở tab terminal
        sh([DRV, bid, "10", "{CMDT}"]); time.sleep(3)
        shot("muxy-after-new-tab")
    dismiss_dialogs()
    if front() != bid:
        sh(["open", "-a", path])
        time.sleep(1)
    return bid


def close_terminal(key):
    _, path = TERMINALS[key]
    sh(["pkill", "-f", f"{path}/Contents/MacOS/"])
    time.sleep(1.5)


GTV_LOG = pathlib.Path.home() / "Library/Logs/GTV-debug.log"


def log_mark():
    return GTV_LOG.stat().st_size if GTV_LOG.exists() else 0


def ime_seen(mark, bid):
    """Số phím GTV thấy (và tự xử lý) ở ứng dụng `bid` kể từ `mark`: bài nào GTV không thấy phím nào là lỗi hạ
    tầng (phím đi vòng bộ gõ, sai chế độ…), không phải PASS/FAIL của GTV."""
    if not GTV_LOG.exists():
        return {"ime_keys": 0, "ime_handled": 0}
    with open(GTV_LOG, "rb") as f:
        f.seek(mark)
        new = f.read().decode("utf-8", "replace").splitlines()
    keys = [l for l in new if " phím " in l and bid in l and "chế độ E" not in l]
    return {"ime_keys": len(keys), "ime_handled": sum("bộ gõ xử lý" in l for l in keys)}


def run_capture(key, bid, name, method, keys, expect, ms):
    dismiss_dialogs()
    log = L / f"{key}-{name}.jsonl"
    log.unlink(missing_ok=True)
    ensure_mode(bid, "en")
    drv(bid, f"python3 /tmp/l/c.py {log} legacy{{RET}}", 15)
    for _ in range(100):
        if log.exists() and "ready" in log.read_text():
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("capture.py không chạy")
    ensure_mode(bid, "vi")
    mark = log_mark()
    drv(bid, keys, ms)
    time.sleep(0.6)
    seen = ime_seen(mark, bid)
    img = shot(f"{key}-{name}")
    source = current_source()
    ensure_mode(bid, "en")
    drv(bid, "{CQ}", 30)
    time.sleep(0.4)
    shutil.copy(log, OUT / "logs" / log.name)
    a = analyze(log)
    r = {"final": a["final"], "pass": a["final"] == expect, "chunks": a["chunks"], "edits": a["edits"],
         "edits_split": a["edits_split"], "escapes": a["escapes"], "raw": a["raw"], "shot": img, "source": source,
         **seen}
    if seen["ime_keys"] == 0:
        r["error"] = "GTV không thấy phím nào (lỗi hạ tầng)"
    return r


def run_fish(key, bid, name, method, keys, expect, ms):
    dismiss_dialogs()
    out = L / f"{key}-{name}.txt"
    out.unlink(missing_ok=True)
    ensure_mode(bid, "en")
    drv(bid, f"cd /tmp/l/fd && fish -N -C \"bind ctrl-x 'commandline > {out}'\"{{RET}}", 15)
    time.sleep(3)
    ensure_mode(bid, "vi")
    mark = log_mark()
    drv(bid, keys, ms)
    time.sleep(0.8)
    seen = ime_seen(mark, bid)
    img = shot(f"{key}-{name}")
    source = current_source()
    drv(bid, "{CX}", 40)
    time.sleep(0.8)
    final = out.read_text().rstrip("\n") if out.exists() else None
    drv(bid, "{CU}", 30)
    ensure_mode(bid, "en")
    drv(bid, "exit{RET}", 30)
    time.sleep(0.8)
    r = {"final": final, "pass": final == expect, "shot": img, "source": source, **seen}
    if seen["ime_keys"] == 0:
        r["error"] = "GTV không thấy phím nào (lỗi hạ tầng)"
    return r


def probe_fields(key, bid):
    """Ô văn bản thường bên trong app terminal (thanh Find ⌘F, command palette): GTV-debug.log ghi thuộc tính
    marked text của từng ô (activateServer … attrs=[…]) để phân biệt với view terminal; chụp chữ gõ vào."""
    out = []
    for name, keys in [("find", "{CMDF}"), ("palette", "{CMDSP}")]:
        if key != "ghostty" and name == "palette":
            continue
        try:
            dismiss_dialogs()
            drv(bid, keys, 30)
            time.sleep(1.0)
            ensure_mode(bid, "vi")
            drv(bid, "Vie65t Nam ", 60)
            time.sleep(0.6)
            img = shot(f"{key}-field-{name}")
            ensure_mode(bid, "en")
            drv(bid, "{ESC}", 30)
            time.sleep(0.5)
            out.append({"terminal": key, "style": "-", "test": f"field-{name}", "expect": None, "final": "", "shot": img})
        except Exception as e:  # noqa: BLE001
            out.append({"terminal": key, "test": f"field-{name}", "error": str(e)})
    return out


def run_modes():
    """Chế độ V/E phải cố định: đổi ứng dụng / hệ thống chọn lại GTV không được làm đổi chế độ;
    người dùng tự đổi thì theo."""
    out = []
    def check(name, expect):
        time.sleep(1.2)
        got = current_source().rsplit(".", 1)[-1]
        out.append({"terminal": "modes", "style": "-", "test": name, "expect": expect, "final": got,
                    "pass": got == expect, "shot": shot(f"modes-{name}")})
        print("modes", name, got, flush=True)
    term = TERMINALS["terminal"]
    sh(["open", "-a", term[1]]); time.sleep(2.5)
    sh([DRV, "-", "20", "{IS:en}"])
    check("start-en", "en")
    for app in ["/System/Applications/TextEdit.app", "/System/Library/CoreServices/Finder.app", term[1]]:
        sh(["open", "-a", app]); check("switch-" + pathlib.Path(app).stem, "en")
    # Ô mật khẩu: secure input bật, hệ thống chuyển sang ABC; rời ô mật khẩu thì hệ thống chọn lại GTV ở chế độ
    # chính "vi" -> GTV giữ "en"
    sh([DRV, "-", "20", "{SECURE:on}{IS:abc}{WAIT800}{SECURE:off}{IS:vi}"]); check("password-return-keeps-en", "en")
    # Người dùng tự chọn ABC rồi tự chọn "Tiếng Việt (GTV)" trong menu bộ gõ -> theo
    sh([DRV, "-", "20", "{TAPSHIFT}{IS:abc}{WAIT1000}{TAPSHIFT}{IS:vi}"]); check("user-abc-then-vi", "vi")
    # Chiều ngược lại: đang "vi", từ ABC chọn "English (GTV)" -> theo
    sh([DRV, "-", "20", "{TAPSHIFT}{IS:abc}{WAIT1000}{TAPSHIFT}{IS:en}"]); check("user-abc-then-en", "en")
    # Người dùng tự đổi (không đổi ứng dụng): theo
    time.sleep(1.0)
    sh([DRV, "-", "20", "{TAPSHIFT}{IS:vi}"]); check("user-switch-to-vi", "vi")
    for app in ["/System/Applications/TextEdit.app", term[1]]:
        sh(["open", "-a", app]); check("switch-vi-" + pathlib.Path(app).stem, "vi")
    # Đổi ứng dụng rồi 0,3 s sau người dùng chọn "English (GTV)" (⌃Space, 🌐…) -> theo, không bị đảo lại
    sh(["open", "-a", "/System/Applications/TextEdit.app"]); time.sleep(0.3)
    sh([DRV, "-", "20", "{TAPSHIFT}{IS:en}"]); check("user-switch-right-after-app-switch", "en")
    sh(["pkill", "-x", "TextEdit"])
    return out


def run_suite(key, bid, style, delay, method, repeat):
    """Các bài của một kiểu gõ trên một terminal; bài capture có kết quả mong đợi thì chạy `repeat` lần."""
    configure(method, style, delay)
    tests = [("capture", t) for t in CAPTURE if t[1] == method]
    if method == "vni":
        tests.append(("capture", ("keys-seen", "vni", KEYS_SEEN, None, 120)))
    if shutil.which("fish"):
        tests += [("fish", t) for t in FISH if t[1] == method]
    out = []
    for kind, (name, _, keys, expect, ms) in tests:
        reps = repeat if kind == "capture" and expect is not None else 1
        for i in range(reps):
            tag = name + (f"-d{delay}" if delay is not None else "") + (f"-r{i + 1}" if reps > 1 else "")
            r = {"terminal": key, "style": style, "test": tag, "expect": expect}
            try:
                run = run_capture if kind == "capture" else run_fish
                r.update(run(key, bid, f"{style}-{tag}", method, keys, expect, ms))
            except Exception as e:  # noqa: BLE001
                r["error"] = str(e)
                shot(f"{key}-{style}-{tag}-error")
            out.append(r)
            print(f"{style}/{tag}", json.dumps({k: v for k, v in r.items() if k != "raw"}, ensure_ascii=False), flush=True)
    return out


def main():
    (OUT / "logs").mkdir(parents=True, exist_ok=True)
    (L / "fd" / "suoddms-quickstart-6.0.23.tar").mkdir(parents=True, exist_ok=True)
    shutil.copy(HERE / "capture.py", L / "c.py")
    subprocess.run(["pbcopy"], input=PASTE, text=True, check=False)
    terms = os.environ.get("TERMS", "terminal ghostty rex muxy kitty wezterm iterm2").split()
    methods = os.environ.get("METHODS", "vni telex").split()
    styles = os.environ.get("STYLES", "marked inline deferred direct").split()
    # Lặp các bài capture để đo lỗi thỉnh thoảng mới gặp; Ghostty (kiểu deferred) chạy với từng độ trễ gửi.
    repeat = int(os.environ.get("REPEAT", "1"))
    delays = os.environ.get("DEFER_DELAYS", "").split()
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
                for delay in (delays if key == "ghostty" and delays else [None]):
                    for method in methods:
                        results += run_suite(key, bid, style, delay, method, repeat)
            if os.environ.get("FIELDS", "1") == "1":
                configure("vni", styles[0])
                results += probe_fields(key, bid)
        except Exception as e:  # noqa: BLE001
            results.append({"terminal": key, "test": "-", "error": str(e)})
            shot(f"{key}-fatal")
        finally:
            close_terminal(key)

    if os.environ.get("MODES_TEST", "1") == "1":
        try:
            results += run_modes()
        except Exception as e:  # noqa: BLE001
            results.append({"terminal": "modes", "test": "-", "error": str(e)})
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
