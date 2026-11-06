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
import re
import shutil
import signal
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
    "herdr": ("dev.herdr.app", "/Applications/Herdr.app"),
}

# (tên, kiểu gõ, phím, mong đợi, ms giữa 2 phím)
TERMINAL_IDS = ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty",
                "com.github.wez.wezterm", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.superlogical.rex",
                "com.muxy.app", "dev.herdr.app"]

CAPTURE = [
    ("vni-words", "vni", "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c.", "Việt Nam, tôi yêu tiếng Việt đại học.", 45),
    ("vni-fast", "vni", "Vie65t Nam, to6i ye6u tie61ng Vie65t d9a5i ho5c.", "Việt Nam, tôi yêu tiếng Việt đại học.", 12),
    ("vni-backspace", "vni", "tie61ng{BS}{BS}{BS}e65t ", "tiệt ", 45),
    ("telex-words", "telex", "Vieetj Nam, tooi yeeu tieengs Vieetj ddaij hocj.", "Việt Nam, tôi yêu tiếng Việt đại học.", 45),
    # ⌘V giữa từ: phím đi vòng bộ gõ (sổ phím phải thấy), chữ dán không được bị xoá. Bộ nhớ tạm: PASTE.
    ("vni-paste", "vni", "tie{CMDV}{WAIT300}6 to6i", "tie/tmp6 tôi", 45),
    # Ứng dụng treo (SIGSTOP) giữa từ: phím dồn lại rồi tới cùng lúc — không bỏ từ oan, chữ vẫn đúng. Log: thời điểm
    # sự kiện của phím dồn lại là lúc bấm hay lúc ứng dụng nhận ("tới sau … ms" trong GTV-debug.log).
    ("vni-stall", "vni", "Vi{STOP}e65t{WAIT600}{CONT}{WAIT800} Nam", "Việt Nam", 120),
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
    # Tab tự hoàn thành (Muxy, Terminal.app: đi vòng bộ gõ) rồi dừng tay, gõ tiếp một từ có dấu.
    ("fish-tab", "vni", "cd suo{TAB}{WAIT500}ta1", "cd suoddms-quickstart-6.0.23.tar/tá", 45),
]


# Ứng dụng thường (không phải terminal): ô Cocoa (NSTextView, GTV thay chữ trực tiếp) và ô Java Swing (GTV phải nhận ra Java
# và gõ bằng marked text). Mỗi ô ghi nội dung ra file. (tên, kiểu gõ, phím, mong đợi, ms giữa 2 phím)
APP_TESTS = [
    ("vni-words", "vni", "Vie65t Nam, d9a5i ho5c d9a38ng ", "Việt Nam, đại học đẳng ", 45),
    ("vni-fast", "vni", "Vie65t Nam, d9a5i ho5c d9a38ng ", "Việt Nam, đại học đẳng ", 12),
    ("telex-words", "telex", "Vieetj Nam, ddaij hocj ", "Việt Nam, đại học ", 45),
    ("vni-backspace", "vni", "tie61ng{BS}{BS}{BS}e65t ", "tiệt ", 45),
    # Phím kết thúc từ không phải chữ: chữ được chốt và phím vẫn có tác dụng (Java nuốt phím sau khi bộ gõ chốt marked
    # text nếu GTV không bật lại cờ phát phím: "việtx").
    # Java: từ đang gạch chân được chốt sau 1 s không gõ (GTV), nên phím đó tới Java như thường.
    ("vni-arrow", "vni", "vie65t{WAIT1300}{LEFT}x ", "việx t", 45),
    ("vni-shortcut", "vni", "vie65t{WAIT1300}{CMDA}{BS}xyz ", "xyz ", 45),
    # Đối chứng: mũi tên khi không có từ đang gõ; mũi tên ngay sau từ (Java: bị nuốt — chỉ ghi lại, không chấm).
    ("vni-arrow-plain", "vni", "ab {LEFT}x ", "abx  ", 45),
    ("vni-arrow-fast", "vni", "vie65t{LEFT}x ", None, 45),
    ("vni-enter", "vni", "vie65t{RET}nam ", "việt\nnam ", 45),
    ("vni-punct", "vni", "d9a38ng, vie65t.", "đẳng, việt.", 45),
]
# Gõ ngay khi cửa sổ vừa được kích hoạt (như TinyCast: ⌘Space rồi gõ liền): phím đầu có thể tới trước lời gọi setValue mà
# InputMethodKit gửi sau mỗi lần gắn bộ gõ — lỗi cũ: "d9a38ng" ra "d9ẳng".
RACE = ("vni", "d9a38ng", "đẳng", 10)
# Chrome (Chromium: cũng là Electron, VS Code, Claude desktop…): gõ rất nhanh (bộ đệm văn bản phía trình duyệt cập nhật
# chậm sau lần thay của bộ gõ: có thể mất dấu) và ⌫ làm dời dấu thanh (kiểu cũ: "hoàn" ⌫ → "hòa"; Chromium có thể vừa
# nhận lần thay của bộ gõ vừa tự xoá).
CHROME_TESTS = APP_TESTS + [
    ("telex-fast8", "telex", "Vieetj Nam ddaij hocj tieengs Vieetj nguwowif ", "Việt Nam đại học tiếng Việt người ", 8),
    ("vni-fast6", "vni", "Vie65t Nam d9a5i ho5c tie61ng Vie65t ngu7o72i ", "Việt Nam đại học tiếng Việt người ", 6),
    ("telex-bs-tone", "telex", "hoafn{BS} ", "hòa ", 45),
    ("vni-bs-tone", "vni", "toa1n{BS} ", "tóa ", 45),
]
# View tự vẽ "mù con trỏ" (field.swift --blind: như view terminal GPUI / Herdr / Zed khi GTV chưa biết ứng dụng): mọi từ phải ra
# đúng (gõ bằng marked text), không từ nào đi nguyên văn. Không có ⌘A (view không có menu Edit).
BLIND_TESTS = [t for t in APP_TESTS if t[0] != "vni-shortcut"] + [
    ("telex-first-word", "telex", "ddawngf ", "đằng ", 45),
    ("vni-first-word-fast", "vni", "d9a82ng tie61ng ", "đằng tiếng ", 10),
]
# Trang chậm (mỗi phím bận 100 ms): người dùng gõ "d9a38ng" ra "đa38ng" / "đả8ng" ở Electron.
CHROME_SLOW_TESTS = [
    ("slow-dang-60", "vni", "d9a38ng ", "đẳng ", 60),
    ("slow-dang-120", "vni", "d9a38ng ", "đẳng ", 120),
    ("slow-vni-words", "vni", "Vie65t Nam, d9a5i ho5c d9a38ng tie61ng ", "Việt Nam, đại học đẳng tiếng ", 70),
    ("slow-telex-words", "telex", "Vieetj Nam ddaij hocj tieengs nguwowif ", "Việt Nam đại học tiếng người ", 70),
    ("slow-bs-tone", "telex", "hoafn{BS} ", "hòa ", 70),
    ("slow-bs-retype", "vni", "tie61ng{BS}{BS}{BS}e65t ", "tiệt ", 70),
]
CHROME = "/Applications/Google Chrome.app"
CHROME_ID = "com.google.Chrome"
FIELD_APP = L / "GTVField.app"
FIELD_ID = "com.gtv.lab.field"


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
    if os.environ.get("LAB_SWITCH", "hotkey") == "tis":
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
    if key == "herdr":     # herdr-core đã cài sẵn (ime-lab.yml): cửa sổ chính + màn chào "Welcome to Herdr" (4 trang, nút
        time.sleep(2)      # mặc định Next / "Open a space") — lab 42066487046: phím của 5 bài đầu đi vào màn chào
        shot("herdr-opened")
        for _ in range(5):
            sh([DRV, bid, "10", "{RET}"]); time.sleep(0.8)
        shot("herdr-after-welcome")
        sh([DRV, bid, "10", "{CMDT}"]); time.sleep(3)
        shot("herdr-after-new-tab")
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


def log_since(mark):
    if not GTV_LOG.exists():
        return ""
    with open(GTV_LOG, "rb") as f:
        f.seek(mark)
        return f.read().decode("utf-8", "replace")


def ime_seen(mark, bid):
    """Số phím GTV thấy (và tự xử lý) ở ứng dụng `bid` kể từ `mark`: bài nào GTV không thấy phím nào là lỗi hạ
    tầng (phím đi vòng bộ gõ, sai chế độ…), không phải PASS/FAIL của GTV."""
    if not GTV_LOG.exists():
        return {"ime_keys": 0, "ime_handled": 0}
    with open(GTV_LOG, "rb") as f:
        f.seek(mark)
        new = f.read().decode("utf-8", "replace").splitlines()
    keys = [l for l in new if " phím " in l and (bid is None or bid in l) and "chế độ E" not in l]
    return {"ime_keys": len(keys), "ime_handled": sum("bộ gõ xử lý" in l for l in keys)}


def app_pid(key):
    _, path = TERMINALS[key]
    out = sh(["pgrep", "-f", f"{path}/Contents/MacOS/"]).stdout.split()
    return int(out[0]) if out else None


def type_keys(key, bid, keys, ms):
    """Gõ `keys`; {STOP} / {CONT}: tạm dừng / chạy tiếp tiến trình terminal (giả lập ứng dụng treo)."""
    for part in re.split(r"(\{STOP\}|\{CONT\})", keys):
        if part == "{STOP}":
            pid = app_pid(key)
            if pid:
                os.kill(pid, signal.SIGSTOP)
        elif part == "{CONT}":
            pid = app_pid(key)
            if pid:
                os.kill(pid, signal.SIGCONT)
        elif part:
            drv(bid, part, ms)


def deliveries(mark):
    """"tới sau … ms" của các phím GTV nhận kể từ `mark` (GTV-debug.log, dòng sổ phím)."""
    if not GTV_LOG.exists():
        return []
    with open(GTV_LOG, "rb") as f:
        f.seek(mark)
        new = f.read().decode("utf-8", "replace").splitlines()
    out = []
    for l in new:
        m = re.search(r"sổ phím: (\S+?)[, ].*tới sau (-?[\d.]+) ms", l)
        if m:
            out.append(f"{m.group(1)}@{m.group(2)}")
    return out


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
    type_keys(key, bid, keys, ms)
    time.sleep(0.6)
    seen = ime_seen(mark, bid)
    if "{STOP}" in keys:
        seen["deliveries"] = deliveries(mark)
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


def front_pid():
    asn = sh(["lsappinfo", "front"]).stdout.strip()
    out = sh(["lsappinfo", "info", "-only", "pid", asn]).stdout
    m = re.search(r"=\s*(\d+)", out)
    return int(m.group(1)) if m else None


def build_field_app():
    """Gói tools/lab/field.swift thành GTVField.app (cần bundle ID để `open -a` kích hoạt và driver kiểm tra phía trước)."""
    exe = FIELD_APP / "Contents/MacOS/field"
    exe.parent.mkdir(parents=True, exist_ok=True)
    sh(["swiftc", "-O", "-o", str(exe), str(HERE / "field.swift")], timeout=300, check=True)
    (FIELD_APP / "Contents/Info.plist").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{FIELD_ID}</string>
<key>CFBundleExecutable</key><string>field</string>
<key>CFBundleName</key><string>GTVField</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
""")


def find_java():
    """JDK 11+ (chạy thẳng file .java): các JDK có sẵn trên máy GitHub (JAVA_HOME_<bản>_<kiến trúc>), rồi java_home."""
    homes = sorted(((int(m.group(1)), v) for k, v in os.environ.items()
                    if (m := re.match(r"JAVA_HOME_(\d+)_", k)) and int(m.group(1)) >= 11), reverse=True)
    for _, home in homes:
        if pathlib.Path(home, "bin/java").exists():
            return str(pathlib.Path(home, "bin/java"))
    r = sh(["/usr/libexec/java_home", "-v", "11+"])
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip() + "/bin/java"
    return shutil.which("java")


def wait_file(p, timeout=20):
    for _ in range(int(timeout * 20)):
        if p.exists():
            return True
        time.sleep(0.05)
    return False


def read_text(p):
    try:
        return p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None


def ime_trace(mark):
    """Các dòng vòng đời bộ gõ (activate/deactivate/setValue/commitComposition) và phím kể từ `mark`, rút gọn."""
    if not GTV_LOG.exists():
        return []
    with open(GTV_LOG, "rb") as f:
        f.seek(mark)
        new = f.read().decode("utf-8", "replace").splitlines()
    keep = []
    for l in new:
        m = re.search(r"(activateServer|deactivateServer|setValue|commitComposition|phím \d+ '[^']*')[^:]*(: [^s]*)?", l)
        if m:
            keep.append(m.group(0)[:80])
    return keep[:40]


def used_underline(app, out_file, name):
    """Bộ gõ có dùng chữ gạch chân (marked text) trong bài không — người dùng muốn không bao giờ có. Swing: InputMethodEvent có
    phần chữ chưa chốt (text dài hơn số ký tự đã chốt) sau dòng "=== <bài>". Ô --blind: file <file>.marked."""
    if app == "blind":
        return "marked text" if pathlib.Path(str(out_file) + ".marked").exists() else ""
    if app != "swing":
        return ""
    ev = pathlib.Path(str(out_file) + ".events")
    if not ev.exists():
        return ""
    lines = ev.read_text(encoding="utf-8", errors="replace").splitlines()
    try:
        start = max(i for i, l in enumerate(lines) if l == f"=== {name}")
    except ValueError:
        return ""
    for l in lines[start + 1:]:
        m = re.match(r"IM committed=(\d+) text=(.*)$", l)
        if m and len(m.group(2)) > int(m.group(1)):
            return l
    return ""


def append_events(out_file, line):
    with open(str(out_file) + ".events", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def clear_field(out_file, web=None):
    """Xoá chữ trong ô thử qua file tín hiệu <file>.clear (trang web: lệnh "clear" của máy chủ thử)."""
    flag = pathlib.Path(str(out_file) + ".clear")
    if web:
        web.cmd = "clear"
    else:
        flag.write_text("1")
    for _ in range(100):
        if not flag.exists() and not (web and web.cmd) and read_text(out_file) == "":
            time.sleep(0.2)
            return
        time.sleep(0.05)
    raise RuntimeError(f"không xoá được ô (còn {read_text(out_file)!r})")


class _Web:
    """Máy chủ nhỏ cho trang thử trong Chrome: trang gửi nội dung ô (POST /t), lấy lệnh xoá (GET /cmd)."""
    PAGE = """<!doctype html><meta charset=utf-8><title>GTV Lab web</title>
<textarea id=t autofocus spellcheck=false autocomplete=off autocorrect=off
 style="width:640px;height:160px;font-size:18px"></textarea>
<script>
const t = document.getElementById('t');
const send = () => fetch('/t', {method: 'POST', body: t.value});
// ?slow=N: trang bận N ms ở mỗi phím (như VS Code / Zalo lúc nặng) — bộ đệm của Chromium chậm vài phím.
const slow = +(new URLSearchParams(location.search).get('slow') || 0);
if (slow) t.addEventListener('keydown', () => { const e = performance.now() + slow; while (performance.now() < e) {} });
t.addEventListener('input', send);
setInterval(async () => {
  t.focus();
  const c = await (await fetch('/cmd')).text();
  if (c === 'clear') { t.value = ''; send(); }
}, 100);
fetch('/ready', {method: 'POST', body: '1'});
</script>"""

    def __init__(self, out_file, ready):
        import http.server
        import threading
        web = self
        self.cmd = ""

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _reply(self, body=b"", ctype="text/plain; charset=utf-8"):
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == "/cmd":
                    c, web.cmd = web.cmd, ""
                    self._reply(c.encode())
                else:
                    self._reply(_Web.PAGE.encode(), "text/html; charset=utf-8")

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(n).decode("utf-8", "replace")
                if self.path == "/t":
                    out_file.write_text(body, encoding="utf-8")
                elif self.path == "/ready":
                    ready.write_text("ready")
                self._reply()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def run_app_suite(app):
    """Bài gõ trong ô của ứng dụng thường. `app`: "field" (Cocoa) hoặc "swing" (Java)."""
    out_file = L / f"{app}.txt"
    ready = pathlib.Path(str(out_file) + ".ready")
    out_file.unlink(missing_ok=True)
    ready.unlink(missing_ok=True)
    proc = None
    results = []
    try:
        web = None
        tests = APP_TESTS
        if app in ("field", "blind"):
            build_field_app()
            sh(["open", "-a", str(FIELD_APP), "--args", str(out_file)] + (["--blind"] if app == "blind" else []))
            bid, pid = FIELD_ID, None
            if app == "blind":
                tests = BLIND_TESTS
        elif app in ("chrome", "chromeslow"):
            if not pathlib.Path(CHROME).exists():
                return [{"terminal": app, "test": "-", "error": "chưa cài Chrome"}]
            # Chrome cài bằng Homebrew cask có cờ quarantine: hộp thoại Gatekeeper "downloaded from the Internet" chặn lab.
            if sh(["xattr", "-dr", "com.apple.quarantine", CHROME]).returncode:
                sh(["sudo", "-n", "xattr", "-dr", "com.apple.quarantine", CHROME])
            web = _Web(out_file, ready)
            tests = CHROME_TESTS if app == "chrome" else CHROME_SLOW_TESTS
            query = "" if app == "chrome" else "?slow=100"
            sh(["open", "-na", CHROME, "--args", "--user-data-dir=/tmp/l/chrome-profile", "--no-first-run",
                "--no-default-browser-check", "--disable-features=Translate", "--new-window",
                f"http://127.0.0.1:{web.port}/{query}"])
            bid, pid = CHROME_ID, None
        else:
            java = find_java()
            if not java:
                return [{"terminal": app, "test": "-", "error": "không có JDK 11+"}]
            proc = subprocess.Popen([java, str(HERE / "SwingField.java"), str(out_file)],
                                    stdout=open(OUT / "logs" / "swing.log", "w"), stderr=subprocess.STDOUT)
            bid, pid = "-", proc.pid
        if not wait_file(ready, 60):
            shot(f"{app}-not-ready")
            return [{"terminal": app, "test": "-", "error": f"ô {app} không sẵn sàng (front={front()}, pid={front_pid()})"}]
        time.sleep(1.0)
        if app in ("chrome", "chromeslow"):
            # Chrome vừa mở còn ì (phím tới trễ cả giây): gõ nháp rồi xoá trước khi chấm.
            time.sleep(3)
            configure("vni", "auto")
            ensure_mode(bid, "vi")
            drv(bid, "khoi dong ", 45)
            time.sleep(2)
            clear_field(out_file, web)
        shot(f"{app}-opened")
        for name, method, keys, expect, ms in tests:
            r = {"terminal": app, "style": "-", "test": name, "expect": expect}
            try:
                if pid is not None and front_pid() != pid:
                    raise RuntimeError(f"ô {app} không ở phía trước (front={front()}, pid={front_pid()})")
                configure(method, "auto")
                ensure_mode(bid, "vi")
                clear_field(out_file, web)
                mark = log_mark()
                if app == "swing":
                    append_events(out_file, f"=== {name}")
                marked_flag = pathlib.Path(str(out_file) + ".marked")
                marked_flag.unlink(missing_ok=True)
                drv(bid, keys, ms)
                time.sleep(0.8)
                got = read_text(out_file)
                underline = used_underline(app, out_file, name)
                r.update({"final": got, "pass": got == expect and not underline, "shot": shot(f"{app}-{name}")})
                if underline:
                    r["underline"] = underline
                r.update(ime_seen(mark, None if app == "swing" else bid))
                if got != expect:
                    r["trace"] = ime_trace(mark)
            except Exception as e:  # noqa: BLE001
                r["error"] = str(e)
                shot(f"{app}-{name}-error")
            results.append(r)
            print(f"{app}/{name}", json.dumps(r, ensure_ascii=False), flush=True)
        if app == "field":
            results += run_race(bid, out_file, ready)
    finally:
        ev = pathlib.Path(str(out_file) + ".events")
        if ev.exists():
            shutil.copy(ev, OUT / "logs" / f"{app}-events.log")
        if proc:
            proc.terminate()
        elif app in ("chrome", "chromeslow"):
            sh(["pkill", "-f", "chrome-profile"])
        else:
            sh(["pkill", "-f", str(FIELD_APP / "Contents/MacOS/field")])
        if web:
            web.close()
        time.sleep(1)
    return results


def run_race(bid, out_file, ready):
    """Rời ô (sang Finder) rồi kích hoạt lại và gõ NGAY khi nó lên phía trước, nhiều lần."""
    method, keys, expect, ms = RACE
    configure(method, "auto")
    ensure_mode(bid, "vi")
    out = []
    for i in range(int(os.environ.get("RACE_REPEAT", "12"))):
        r = {"terminal": "field", "style": "-", "test": f"race-{i + 1}", "expect": expect}
        try:
            sh(["open", "-a", "Finder"])
            for _ in range(60):
                if front() == "com.apple.finder" and not ready.exists():
                    break
                time.sleep(0.05)
            time.sleep(0.5)
            mark = log_mark()
            sh(["open", "-a", str(FIELD_APP)])
            for _ in range(400):
                if front() == bid:
                    break
                time.sleep(0.005)
            drv(bid, keys, ms)
            time.sleep(0.8)
            got = read_text(out_file)
            r.update({"final": got, "pass": got == expect, "trace": ime_trace(mark)})
            r.update(ime_seen(mark, bid))
            if got != expect:
                r["shot"] = shot(f"field-race-{i + 1}")
        except Exception as e:  # noqa: BLE001
            r["error"] = str(e)
        out.append(r)
        print(f"field/race-{i + 1}", json.dumps(r, ensure_ascii=False), flush=True)
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
    mark = log_mark()
    sh(["open", "-a", term[1]])
    # Chờ GTV thật sự gắn vào ô của Terminal (dòng activateServer trong log) rồi thêm 1,5 s. Terminal ở phía trước (lsappinfo)
    # chưa đủ: khởi động lạnh thì cửa sổ hiện muộn, macOS khôi phục chế độ Terminal đã nhớ sau thao tác của lab và GTV coi đó
    # là người dùng chọn (lab 42044377600, 42057042497).
    for _ in range(150):
        if front() == term[0] and f"activateServer {term[0]}" in log_since(mark):
            break
        time.sleep(0.1)
    time.sleep(1.5)
    sh([DRV, "-", "20", "{TAPSHIFT}{IS:en}"])
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
    # Từ ABC chọn lại một chế độ của GTV, lặp nhiều lần: macOS gắn GTV vào ô rồi mới báo chế độ người dùng chọn — GTV không
    # được chọn đè chế độ cũ, lời báo cho lần GTV tự chọn không phải người dùng chọn (lab 42055281996, có lúc mới gặp).
    for i in range(int(os.environ.get("MODES_REPEAT", "3"))):
        for target in ("vi", "en"):
            sh([DRV, "-", "20", "{TAPSHIFT}{IS:abc}{WAIT1000}{TAPSHIFT}{IS:" + target + "}"])
            check(f"user-abc-then-{target}-{i + 1}", target)
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
    terms = os.environ.get("TERMS", "terminal ghostty rex muxy herdr kitty wezterm iterm2").split()
    methods = os.environ.get("METHODS", "vni telex").split()
    styles = os.environ.get("STYLES", "marked inline deferred direct").split()
    # Lặp các bài capture để đo lỗi thỉnh thoảng mới gặp; Ghostty (kiểu deferred) chạy với từng độ trễ gửi.
    repeat = int(os.environ.get("REPEAT", "1"))
    delays = os.environ.get("DEFER_DELAYS", "").split()
    # COUNTER_MODES: "auto" = GTV tự nhận biết bộ đếm sự kiện (macOS 26: cập nhật ngay); "coarse" = ép chế độ của macOS 27
    # (bộ đếm chỉ công bố mỗi 0,5 s: không dùng sổ phím, chỉ đọc trạng thái phím / nút chuột) — máy GitHub chưa có macOS 27.
    # Mỗi terminal chỉ mở một lần, chạy lần lượt các chế độ (mở lại iTerm2 lần hai hay kẹt hộp thoại).
    counter_modes = os.environ.get("COUNTER_MODES", "auto").split()

    def set_counter_mode(mode):
        d = "com.gtv.inputmethod.GTV"
        if mode == "auto":
            sh(["defaults", "delete", d, "counterMode"])
        else:
            sh(["defaults", "write", d, "counterMode", "-string", mode])
        sh(["notifyutil", "-p", "com.gtv.lab.reload"])
        time.sleep(0.4)
        return "" if mode == "auto" else f"·{mode}"

    results = []
    for key in terms:
        if key not in TERMINALS or not pathlib.Path(TERMINALS[key][1]).exists():
            results.append({"terminal": key, "test": "-", "error": "chưa cài"})
            continue
        bid = None
        try:
            bid = open_terminal(key)
            shot(f"{key}-opened")
            for counter_mode in counter_modes:
                suffix = set_counter_mode(counter_mode)
                part = []
                try:
                    for style in styles:
                        for delay in (delays if key == "ghostty" and delays else [None]):
                            for method in methods:
                                part += run_suite(key, bid, style, delay, method, repeat)
                    if os.environ.get("FIELDS", "1") == "1" and counter_mode == counter_modes[0]:
                        configure("vni", styles[0])
                        part += probe_fields(key, bid)
                except Exception as e:  # noqa: BLE001
                    part.append({"terminal": key, "test": "-", "error": str(e)})
                    shot(f"{key}{suffix}-fatal")
                for r in part:
                    r["terminal"] = r.get("terminal", key) + suffix
                results += part
        except Exception as e:  # noqa: BLE001
            results.append({"terminal": key, "test": "-", "error": str(e)})
            shot(f"{key}-fatal")
        finally:
            close_terminal(key)

    for app in os.environ.get("APPS", "field blind swing chrome").split():
        try:
            results += run_app_suite(app)
        except Exception as e:  # noqa: BLE001
            results.append({"terminal": app, "test": "-", "error": str(e)})
            shot(f"{app}-fatal")

    if os.environ.get("MODES_TEST", "1") == "1":
        for counter_mode in counter_modes:
            suffix = set_counter_mode(counter_mode)
            try:
                part = run_modes()
            except Exception as e:  # noqa: BLE001
                part = [{"terminal": "modes", "test": "-", "error": str(e)}]
            for r in part:
                r["terminal"] = r.get("terminal", "modes") + suffix
            results += part
    set_counter_mode("auto")
    (OUT / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1))
    rows = ["| terminal | kiểu | bài | kết quả | shell nhận | xoá tách rời | ghi chú |", "|---|---|---|---|---|---|---|"]
    for r in results:
        ok = "lỗi" if "error" in r else ("✅" if r.get("pass") else "❌")
        split = f"{r.get('edits_split', '')}/{r.get('edits', '')}" if "edits" in r else ""
        note = r.get("error", "") or ("mong đợi: " + r["expect"] if not r.get("pass") and r.get("expect") is not None else "")
        rows.append(f"| {r['terminal']} | {r.get('style', '')} | {r['test']} | {ok} | `{r.get('final', '')}` | {split} | {note} |")
    md = "\n".join(rows)
    (OUT / "summary.md").write_text(md + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## IME Lab\n\n" + md + "\n")
    print(md)


if __name__ == "__main__":
    main()
