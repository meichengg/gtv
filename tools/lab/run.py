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
    # ⌫ bấm ngay sau phím dấu (3 ms).
    ("vni-bs-burst", "vni", "ho5{BS}a d9{BS}e ", "ha e ", 3),
    # Gõ rất nhanh (3 ms giữa hai phím): người dùng báo "gõ nhanh thì không ra dấu mà ra số".
    ("vni-fast3", "vni", "d9a38ng ca61p tuye65t d9o61i ", "đẳng cấp tuyệt đối ", 3),
    # ⌥⌫ (xoá cả từ) rồi gõ tiếp: người dùng báo "ấn ⌥⌫ xong không gõ dấu được nữa". Chờ 1,3 s trước ⌥⌫: ô Java soạn từng từ
    # nuốt phím bấm ngay sau từ (xem vni-arrow).
    ("vni-optbs", "vni", "tie61ng vie65t{WAIT1300}{OPTBS}d9a38ng ca61p ", "tiếng đẳng cấp ", 45),
    # Từ viết tắt có đ (đ đứng đầu không bị trả về phím gõ; đ không đứng đầu), tên riêng viết k trước a, số dính liền chữ.
    ("vni-abbrev", "vni", "HD9 d9c ND9-CP Ba81c Ka5n i18n ", "HĐ đc NĐ-CP Bắc Kạn i18n ", 45),
    ("telex-abbrev", "telex", "HDD ddc keeper Kanj ", "HĐ đc keeper Kạn ", 45),
]
# Gõ sai, xoá cả từ (⌥⌫) hay cả dòng (⌘⌫) rồi gõ lại NGAY, không ngừng tay — người dùng báo: từ gõ lại ra số (VNI) thay vì ra
# dấu, trong Claude desktop / Zalo (Chromium). Ô Chromium trả lời vị trí con trỏ từ một bộ đệm; ngay sau phím xoá bộ gõ chưa chắc
# con trỏ ở đâu, bản cũ bỏ dấu của mọi từ gõ liền sau đó.
DELETE_RETYPE_TESTS = [
    ("vni-optbs-now", "vni", "tie61ng vie65t{OPTBS}d9a38ng ca61p ", "tiếng đẳng cấp ", 45),
    ("vni-optbs-fast", "vni", "tie61ng vie65t{OPTBS}d9a38ng ca61p ", "tiếng đẳng cấp ", 8),
    ("telex-optbs-now", "telex", "tieengs vieetj{OPTBS}ddawngr caaps ", "tiếng đẳng cấp ", 45),
    ("vni-cmdbs-now", "vni", "tuye65t vo72i{CMDBS}d9a38ng ca61p tuye65t ", "đẳng cấp tuyệt ", 45),
    ("telex-cmdbs-now", "telex", "tuyeetj vowis{CMDBS}ddawngr caaps tuyeetj ", "đẳng cấp tuyệt ", 45),
    ("vni-optbs-twice", "vni", "xin chao tuye65t {OPTBS}{OPTBS}d9a38ng ca61p ", "xin đẳng cấp ", 45),
    ("vni-retype-loop", "vni", "tuye65{OPTBS}tuye65{OPTBS}tuye65t d9o61i ", "tuyệt đối ", 30),
    ("vni-optbs-raw-word", "vni", "tuye65{OPTBS}d9a38ng{OPTBS}d9o61i ", "đối ", 20),
]
# Ô Java gõ trực tiếp (JetBrains Runtime, hay JDK gốc có trợ thủ GTV trong máy ảo): không có gì đang soạn, nên phím bấm
# ngay sau từ (mũi tên, ⌘A, ⌥⌫) tới Java như thường; ô một dòng phía trên (như ô đổi tên tab của Burp) gõ như ô chính, kể cả
# khi focus sang đó bằng chương trình (bộ gõ không được gắn lại).
JAVA_DIRECT_TESTS = APP_TESTS + [
    ("vni-arrow-now", "vni", "vie65t{LEFT}x ", "việx t", 45),
    ("vni-shortcut-now", "vni", "vie65t{CMDA}{BS}xyz ", "xyz ", 45),
    ("vni-optbs-now", "vni", "tie61ng vie65t{OPTBS}d9a38ng ca61p ", "tiếng đẳng cấp ", 45),
    ("vni-optbs-fast", "vni", "tie61ng vie65t{OPTBS}d9a38ng ca61p ", "tiếng đẳng cấp ", 5),
    ("telex-fast3", "telex", "ddawngr caaps tuyeetj ddoois ", "đẳng cấp tuyệt đối ", 3),
    ("java-focus", "vni", "tie61ng{FOCUS:title}d9a38ng ca61p", "tiếng|đẳng cấp", 45),
    ("java-focus-back", "vni", "{FOCUS:title}tuye65t{FOCUS:area}d9o61i ", "đối |tuyệt", 45),
    ("java-title-fast", "vni", "{FOCUS:title}d9a38ng ca61p tuye65t d9o61i", "|đẳng cấp tuyệt đối", 3),
    # Ô Java gõ trực tiếp chỉ nhận trọn một lần sửa mỗi phím (JetBrains Runtime: chữ của phím đè mất chữ bộ gõ vừa đưa — lab
    # 44247794337: "keeper " ra "ke "; AWT gốc + trợ thủ: phím không ra chữ sau lần sửa bị bỏ). Lần sửa cuối từ đi cùng chữ
    # của phím kết thúc từ; ⌫ làm dời dấu thì bộ gõ tự xoá; phím kết thúc từ không ra chữ (⏎) thì không sửa, chữ để nguyên.
    ("telex-wordend", "telex", "user thuwor huow, keeper ", "user thuở huơ, keeper ", 45),
    ("vni-wordend", "vni", "thu7o3 hu7o tie61 d9a38ng ", "thuở huơ tie61 đẳng ", 45),
    ("telex-bs-tone", "telex", "hoafn{BS} ", "hòa ", 45),
    ("vni-bs-tone", "vni", "toa1n{BS} ", "tóa ", 45),
    ("telex-wordend-enter", "telex", "thuwor{RET}x ", "thửo\nx ", 45),
]
# Có trợ thủ: focus ở một nút (ô không nhận chữ, như bảng / cây của Burp) thì phím đi thẳng — không có gì được soạn; quay
# lại ô văn bản thì gõ tiếp như thường.
JAVA_HELPER_TESTS = JAVA_DIRECT_TESTS + [
    ("java-focus-button", "vni", "tie61ng{FOCUS:button}d9a38ng{FOCUS:area} ca61p ", "tiếng cấp |", 45),
]
# Ô Java soạn từng từ (JDK gốc, không có trợ thủ): đổi ô bằng chương trình thì Java tự chốt từ đang soạn.
JAVA_COMPOSE_TESTS = APP_TESTS + [
    ("java-focus", "vni", "tie61ng{FOCUS:title}d9a38ng ca61p{WAIT1300}", "tiếng|đẳng cấp", 45),
    # ⌥⌫ bấm ngay sau từ đang soạn: AWT nuốt chính phím đó (như mũi tên) — chỉ ghi lại; nhưng các từ gõ SAU đó vẫn phải ra
    # đúng dấu (người dùng báo: "ấn ⌥⌫ xong không gõ dấu được nữa").
    ("vni-optbs-now", "vni", "tie61ng vie65t{OPTBS}d9a38ng ca61p ", None, 45),
    ("vni-optbs-twice", "vni", "tie61ng vie65t{OPTBS}{OPTBS}d9a38ng ca61p tuye65t ", None, 45),
    ("vni-after-optbs", "vni", "d9o61i ", "đối ", 45),
]
# Gõ ngay khi cửa sổ vừa được kích hoạt (như TinyCast: ⌘Space rồi gõ liền): phím đầu có thể tới trước lời gọi setValue mà
# InputMethodKit gửi sau mỗi lần gắn bộ gõ — lỗi cũ: "d9a38ng" ra "d9ẳng".
RACE = ("vni", "d9a38ng", "đẳng", 10)
# Gõ dở một từ (phím cuối là phím dấu — lần thay cùng độ dài), xoá bằng ⌥⌫ / ⌘⌫ rồi gõ lại: nhật ký máy người dùng 2026-11-19
# (VS Code 1.147, Zalo) — từ gõ lại ra số, các từ sau cũng vậy tới khi ⏎ / ⌘Tab. Ô EditContext (VS Code) chỉ báo lại cho bộ đệm
# của Chromium khi con trỏ đổi chỗ: sau phím dấu bộ đệm còn chữ cũ.
WEB_PARTIAL_TESTS = [
    ("vni-optbs-partial", "vni", "d9a38ng tie61{WAIT400}{OPTBS}{WAIT250}tie61ng vie65t ", "đẳng tiếng việt ", 100),
    ("vni-optbs-partial-fast", "vni", "d9a38ng tie61{OPTBS}tie61ng vie65t ", "đẳng tiếng việt ", 35),
    ("vni-cmdbs-partial", "vni", "xin d9a38ng tie61{WAIT400}{CMDBS}{WAIT250}tie61ng vie65t ", "tiếng việt ", 100),
    ("telex-optbs-partial", "telex", "ddawngr tiees{WAIT400}{OPTBS}{WAIT250}tieengs vieejt ", "đẳng tiếng việt ", 100),
    ("vni-optbs-partial-loop", "vni", "xin tie61{OPTBS}tie61{OPTBS}tie61ng vie65{OPTBS}vie65t ", "xin tiếng việt ", 60),
]
# Không chữ thô nào được ra trang rồi mới được sửa lại (người dùng báo 2026-11-19, VS Code + Claude desktop: gõ "đẳng cấp",
# ⌘⌫, gõ lại thì thấy "d9…" hiện ra rồi nhảy thành chữ có dấu). Nhật ký máy đó: ⌘⌫ bấm hai lần (lần sau không còn gì để xoá —
# con trỏ đứng yên, bộ đệm không cho biết trang đã xử lý nó chưa), nhiều phím tắt liền nhau, ⌫ rồi ⌘⌫. Gõ ở tốc độ người
# (110 ms / phím). Chấm cả chữ cuối cùng lẫn số lần bộ gõ phải cho chữ đi nguyên văn (`raw_flash`, đọc từ GTV-debug.log).
WEB_FLASH_TESTS = [
    ("flash-cmdbs", "vni", "d9a38ng ca61p{CMDBS}{WAIT300}d9a38ng ca61p ", "đẳng cấp ", 110),
    ("flash-cmdbs-twice", "vni", "d9a38ng ca61p{CMDBS}{WAIT120}{CMDBS}{WAIT280}d9a38ng ca61p ", "đẳng cấp ", 110),
    ("flash-cmdbs-many", "vni", "d9a38ng ca61p{CMDBS}{WAIT600}{CMDBS}{WAIT900}{CMDBS}{WAIT160}{CMDBS}{WAIT300}d9a38ng ca61p ",
     "đẳng cấp ", 110),
    ("flash-bs-cmdbs", "vni", "d9a38ng ca61p{WAIT500}{BS}{WAIT700}{CMDBS}{WAIT450}d9a38ng ca61p ", "đẳng cấp ", 110),
    ("flash-optbs-twice", "vni", "xin chao tuye65t{OPTBS}{WAIT150}{OPTBS}{WAIT300}d9a38ng ca61p ", "xin đẳng cấp ", 110),
    ("flash-telex-cmdbs-twice", "telex", "ddawngr caaps{CMDBS}{WAIT120}{CMDBS}{WAIT280}ddawngr caaps ", "đẳng cấp ", 110),
    # Bắt đầu gõ sau một lúc nghỉ, phím dấu là phím thứ hai của từ.
    ("flash-first-tone", "vni", "{WAIT1300}d9i a1 o6ng d9a38ng ", "đi á ông đẳng ", 120),
]
FLASH_NAMES = {t[0] for t in WEB_FLASH_TESTS}
# Ô EditContext / contenteditable: không có ⏎ / mũi tên / ⌘A của các bài chung (trang thử tự xử lý phím theo cách riêng).
WEB_EDIT_TESTS = [t for t in APP_TESTS if t[0] in ("vni-words", "vni-fast", "telex-words", "vni-backspace", "vni-punct",
                                                    "vni-bs-burst", "vni-fast3", "vni-abbrev", "telex-abbrev")] \
    + DELETE_RETYPE_TESTS + WEB_PARTIAL_TESTS + WEB_FLASH_TESTS
# Chrome (Chromium: cũng là Electron, VS Code, Claude desktop…): gõ rất nhanh (bộ đệm văn bản phía trình duyệt cập nhật
# chậm sau lần thay của bộ gõ: có thể mất dấu) và ⌫ làm dời dấu thanh (kiểu cũ: "hoàn" ⌫ → "hòa"; Chromium có thể vừa
# nhận lần thay của bộ gõ vừa tự xoá).
CHROME_TESTS = APP_TESTS + DELETE_RETYPE_TESTS + WEB_PARTIAL_TESTS + WEB_FLASH_TESTS + [
    ("telex-fast8", "telex", "Vieetj Nam ddaij hocj tieengs Vieetj nguwowif ", "Việt Nam đại học tiếng Việt người ", 8),
    ("vni-fast6", "vni", "Vie65t Nam d9a5i ho5c tie61ng Vie65t ngu7o72i ", "Việt Nam đại học tiếng Việt người ", 6),
    ("telex-bs-tone", "telex", "hoafn{BS} ", "hòa ", 45),
    ("vni-bs-tone", "vni", "toa1n{BS} ", "tóa ", 45),
]
# View tự vẽ "mù con trỏ" (field.swift --blind: như view terminal GPUI / Herdr / Zed khi GTV chưa biết ứng dụng): mọi từ phải ra
# đúng (gõ bằng marked text), không từ nào đi nguyên văn. Không có ⌘A (view không có menu Edit).
BLIND_TESTS = [t for t in APP_TESTS if t[0] not in ("vni-shortcut", "vni-optbs")] + [
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
    # Trang chậm: từ gõ lại có thể đi nguyên văn (bộ gõ không sửa ở chỗ chưa chắc) — chỉ ghi lại, không chấm.
    ("slow-optbs", "vni", "tie61ng vie65t{OPTBS}d9a38ng ca61p ", None, 70),
    ("slow-cmdbs", "vni", "tuye65t vo72i{CMDBS}d9a38ng ca61p tuye65t ", None, 70),
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


def web_flash(mark):
    """Ô web kể từ `mark` (GTV-debug.log): số lần bộ gõ phải cho chữ đi nguyên văn rồi sửa lại sau (`raw_flash` — người dùng
    thấy "d9" nhảy thành "đ"), và các lần hỏi trang đồng bộ (số lần được / không, lần lâu nhất)."""
    lines = log_since(mark).splitlines()
    out = {"raw_flash": sum("tạm đi nguyên văn" in l for l in lines)}
    asked = [l for l in lines if "hỏi trang (đồng bộ)" in l]
    if asked:
        ms = [int(m.group(1)) for l in asked for m in [re.search(r"sau (\d+) ms", l)] if m]
        out["settle"] = {"ok": sum(") được sau" in l for l in asked), "fail": sum("không được" in l for l in asked),
                         "max_ms": max(ms) if ms else None}
        # Hai câu hỏi của một lần hỏi đồng bộ, đo riêng: chỗ con trỏ trên màn hình, rồi "ký tự ở điểm này" (câu Chromium phải
        # hỏi sang trang). Câu nào mất cỡ thời gian trang đang bận thì chính câu đó chờ trang.
        probes = [l.split(" hỏi đồng bộ: ", 1)[1][:160] for l in lines if " hỏi đồng bộ: " in l]
        both = [m for l in probes for m in [re.search(r"\) (\d+) µs; ký tự ở điểm=(-?\d+) (\d+) µs", l)] if m]
        if both:
            line_us = sorted(int(m.group(1)) for m in both)
            index_us = sorted(int(m.group(3)) for m in both)
            out["settle"]["line_us"] = [line_us[0], line_us[len(line_us) // 2], line_us[-1]]
            out["settle"]["index_us"] = [index_us[0], index_us[len(index_us) // 2], index_us[-1]]
            out["settle"]["index_values"] = sorted({int(m.group(2)) for m in both})[:8]
        out["settle"]["sample"] = probes[:3]
    out["anchored"] = sum("trang đã trả lời — vị trí chắc chắn" in l for l in lines)
    return out


def set_settle(on, probe=None):
    """Lượt đối chứng: bản Debug bỏ câu hỏi đồng bộ (`labNoSettle`) — bộ gõ gõ như trước khi có nó. `probe`: thứ tự hai câu hỏi
    ("index-first": hỏi "ký tự ở điểm này" trước, để đo riêng câu đó có chờ trang không)."""
    d = "com.gtv.inputmethod.GTV"
    if on:
        sh(["defaults", "delete", d, "labNoSettle"])
    else:
        sh(["defaults", "write", d, "labNoSettle", "-bool", "true"])
    if probe:
        sh(["defaults", "write", d, "labSettleProbe", "-string", probe])
    else:
        sh(["defaults", "delete", d, "labSettleProbe"])
    sh(["notifyutil", "-p", "com.gtv.lab.reload"])
    time.sleep(0.6)


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


def find_jbr():
    """JetBrains Runtime (bản SDK mới nhất, chạy thẳng file .java): AWT của nó nhận vùng thay chữ của bộ gõ — IntelliJ, Android
    Studio, ứng dụng Compose Desktop. Tải một lần vào /tmp/l/jbr."""
    home = L / "jbr"
    found = sorted(home.glob("*/Contents/Home/bin/java"))
    if found:
        return str(found[0])
    # API của GitHub giới hạn số lần gọi không kèm token theo địa chỉ IP (máy CI dùng chung IP: hay bị từ chối).
    auth = ["-H", f"Authorization: Bearer {os.environ['GH_TOKEN']}"] if os.environ.get("GH_TOKEN") else []
    r = sh(["curl", "-sfL", "--retry", "3", *auth,
            "https://api.github.com/repos/JetBrains/JetBrainsRuntime/releases/latest"], timeout=90)
    arch = "aarch64" if os.uname().machine == "arm64" else "x64"
    m = re.search(rf"https://cache-redirector\.jetbrains\.com/intellij-jbr/jbrsdk-[0-9.]+-osx-{arch}-b[0-9.]+\.tar\.gz", r.stdout)
    if not m:
        return None
    home.mkdir(parents=True, exist_ok=True)
    tar = home / "jbr.tar.gz"
    if sh(["curl", "-sfL", "--retry", "5", "--retry-all-errors", m.group(0), "-o", str(tar)], timeout=600).returncode:
        return None
    sh(["tar", "-xzf", str(tar), "-C", str(home)], timeout=300)
    tar.unlink(missing_ok=True)
    found = sorted(home.glob("*/Contents/Home/bin/java"))
    return str(found[0]) if found else None


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


def drive(bid, keys, ms, out_file):
    """Gõ `keys`. {FOCUS:<ô>} (app Swing): chuyển focus sang ô "title" / "area" bằng chương trình, không click."""
    parts = re.split(r"\{FOCUS:(\w+)\}", keys)
    for i, part in enumerate(parts):
        if i % 2:
            flag = pathlib.Path(str(out_file) + ".focus")
            flag.write_text(part)
            for _ in range(100):
                if not flag.exists():
                    break
                time.sleep(0.02)
            time.sleep(0.25)
        elif part:
            drv(bid, part, ms)


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
    """Ô có vẽ gạch chân cho chữ đang gõ trong bài không — người dùng muốn không bao giờ có. Bộ gõ soạn từ bằng marked text của
    InputMethodKit kèm thuộc tính "không gạch chân"; ô vẽ gạch chân hay không là do nó nhận được gì:
    - Swing: InputMethodEvent có phần chữ chưa chốt mang INPUT_METHOD_HIGHLIGHT (hl=1) sau dòng "=== <bài>" — AWT của JDK gốc
      luôn gắn; JetBrains Runtime thì bộ gõ thay chữ trực tiếp, không có phần đang soạn.
    - Ô --blind: file <file>.marked (phần đang soạn tới ô là chuỗi thường hay có kiểu gạch chân nhìn thấy được)."""
    if app == "blind":
        return "gạch chân" if pathlib.Path(str(out_file) + ".marked").exists() else ""
    if not app.startswith("swing"):
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
        m = re.search(r"IM committed=(\d+) hl=(\d) text=(.*)$", l)
        if m and len(m.group(3)) > int(m.group(1)) and m.group(2) == "1":
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
const q = new URLSearchParams(location.search);
const t = document.getElementById('t');
let value = () => t.value, clear = () => { t.value = ''; }, focus = () => t.focus();
const send = () => fetch('/t', {method: 'POST', body: value()});
// ?slow=N: trang bận N ms ở mỗi phím (như VS Code / Zalo lúc nặng) — bộ đệm của Chromium chậm vài phím.
const slow = +(q.get('slow') || 0);
const box = 'width:640px;height:160px;font:18px monospace;border:1px solid #888;white-space:pre-wrap;outline:none';
if (q.get('ec')) {
  // ?ec=1: ô dùng EditContext như VS Code (từ 1.101): trang tự giữ chữ + con trỏ, tự xử lý ⌫ / ⌥⌫ / ⌘⌫ / ⏎ ở keydown, rồi
  // đặt lại chữ và vùng chọn của EditContext theo mô hình. Chromium chỉ báo lại cho phía trình duyệt khi vùng chọn đổi:
  // lần thay cùng độ dài của bộ gõ (phím dấu) để bộ đệm giữ chữ cũ.
  const e = document.createElement('div');
  e.tabIndex = 0; e.style = box;
  t.replaceWith(e);
  const ec = new EditContext();
  e.editContext = ec;
  let text = '', caret = 0;
  const sync = () => {
    ec.updateText(0, ec.text.length, text);
    ec.updateSelection(caret, caret);
    e.textContent = text;
    send();
  };
  ec.addEventListener('textupdate', ev => {
    text = text.slice(0, ev.updateRangeStart) + ev.text + text.slice(ev.updateRangeEnd);
    caret = ev.selectionStart;
    setTimeout(sync, 0);
  });
  window.gtvState = () => ({text, caret});
  e.addEventListener('keydown', ev => {
    let i = caret;
    if (ev.key === 'Backspace' && ev.altKey) {
      while (i > 0 && text[i - 1] === ' ') i--;
      while (i > 0 && text[i - 1] !== ' ' && text[i - 1] !== '\\n') i--;
      text = text.slice(0, i) + text.slice(caret); caret = i;
    } else if (ev.key === 'Backspace' && ev.metaKey) {
      while (i > 0 && text[i - 1] !== '\\n') i--;
      text = text.slice(0, i) + text.slice(caret); caret = i;
    } else if (ev.key === 'Backspace') {
      if (caret > 0) { text = text.slice(0, caret - 1) + text.slice(caret); caret--; }
    } else if (ev.key === 'Enter') {
      text = text.slice(0, caret) + '\\n' + text.slice(caret); caret++;
    } else if (ev.key === 'ArrowLeft') {
      if (caret > 0) caret--;
    } else if (ev.key === 'ArrowRight') {
      if (caret < text.length) caret++;
    } else {
      return;
    }
    ev.preventDefault();
    sync();
  });
  value = () => text;
  clear = () => { text = ''; caret = 0; sync(); };
  focus = () => e.focus();
} else if (q.get('ce')) {
  // ?ce=1: ô contenteditable như ô chat của Zalo / Claude / Slack.
  const e = document.createElement('div');
  e.contentEditable = 'true'; e.spellcheck = false; e.style = box;
  t.replaceWith(e);
  value = () => e.innerText.replace(/\\u00a0/g, ' ').replace(/\\n$/, '');
  clear = () => { e.textContent = ''; };
  focus = () => e.focus();
  e.addEventListener('input', send);
} else {
  if (slow) t.addEventListener('keydown', () => { const e = performance.now() + slow; while (performance.now() < e) {} });
  t.addEventListener('input', send);
}
setInterval(async () => {
  focus();
  const c = await (await fetch('/cmd')).text();
  if (c === 'clear') { clear(); send(); }
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


def run_app_suite(app, only=None, tag=None):
    """Bài gõ trong ô của ứng dụng thường. `app`: "field" (Cocoa), "blind", "swing" (Java, JDK gốc), "swingjbr" (JetBrains
    Runtime), "swinghelper" (JDK gốc, máy ảo nạp trợ thủ Java của GTV). `only`: chỉ chạy các bài có tên trong đó; `tag`: hậu tố cho file log (lượt đo cách gắn thuộc tính)."""
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
            else:
                tests = APP_TESTS + DELETE_RETYPE_TESTS
        elif app in ("chrome", "chromeslow", "chromeec", "chromece"):
            if not pathlib.Path(CHROME).exists():
                return [{"terminal": app, "test": "-", "error": "chưa cài Chrome"}]
            # Chrome cài bằng Homebrew cask có cờ quarantine: hộp thoại Gatekeeper "downloaded from the Internet" chặn lab.
            if sh(["xattr", "-dr", "com.apple.quarantine", CHROME]).returncode:
                sh(["sudo", "-n", "xattr", "-dr", "com.apple.quarantine", CHROME])
            web = _Web(out_file, ready)
            tests = {"chrome": CHROME_TESTS, "chromeslow": CHROME_SLOW_TESTS}.get(app, WEB_EDIT_TESTS)
            query = {"chrome": "", "chromeslow": "?slow=100", "chromeec": "?ec=1", "chromece": "?ce=1"}[app]
            sh(["open", "-na", CHROME, "--args", "--user-data-dir=/tmp/l/chrome-profile", "--no-first-run",
                "--no-default-browser-check", "--disable-features=Translate", "--new-window",
                f"http://127.0.0.1:{web.port}/{query}"])
            bid, pid = CHROME_ID, None
        else:
            java = find_jbr() if app == "swingjbr" else find_java()
            if not java:
                return [{"terminal": app, "test": "-", "error": "không có JetBrains Runtime" if app == "swingjbr" else "không có JDK 11+"}]
            print(app, "java:", java, sh([java, "-version"]).stderr.strip().replace("\n", " | "), flush=True)
            cmd = [java]
            tests = JAVA_COMPOSE_TESTS if app == "swing" else JAVA_HELPER_TESTS if app == "swinghelper" else JAVA_DIRECT_TESTS
            if app == "swinghelper":
                # Bản trợ thủ đi kèm chính bộ gõ đang thử (cũng là thử việc đóng gói).
                jar = IM / "Contents/Resources/gtv-java-helper.jar"
                if not jar.exists():
                    return [{"terminal": app, "test": "-", "error": f"bộ gõ không kèm {jar.name}"}]
                cmd.append(f"-javaagent:{jar}")
            proc = subprocess.Popen(cmd + [str(HERE / "SwingField.java"), str(out_file)],
                                    stdout=open(OUT / "logs" / f"{app}.log", "w"), stderr=subprocess.STDOUT)
            bid, pid = "-", proc.pid
        if not wait_file(ready, 60):
            shot(f"{app}-not-ready")
            return [{"terminal": app, "test": "-", "error": f"ô {app} không sẵn sàng (front={front()}, pid={front_pid()})"}]
        time.sleep(1.0)
        if app.startswith("chrome"):
            # Chrome vừa mở còn ì (phím tới trễ cả giây): gõ nháp rồi xoá trước khi chấm.
            time.sleep(3)
            configure("vni", "auto")
            ensure_mode(bid, "vi")
            drv(bid, "khoi dong ", 45)
            time.sleep(2)
            clear_field(out_file, web)
        shot(f"{app}-opened")
        if only:
            tests = [t for t in tests if t[0] in only]
        pathlib.Path(str(out_file) + ".attrs").unlink(missing_ok=True)
        for name, method, keys, expect, ms in tests:
            r = {"terminal": app, "style": "-", "test": name, "expect": expect}
            try:
                if pid is not None and front_pid() != pid:
                    raise RuntimeError(f"ô {app} không ở phía trước (front={front()}, pid={front_pid()})")
                configure(method, "auto")
                ensure_mode(bid, "vi")
                clear_field(out_file, web)
                mark = log_mark()
                if app.startswith("swing"):
                    append_events(out_file, f"=== {name}")
                marked_flag = pathlib.Path(str(out_file) + ".marked")
                marked_flag.unlink(missing_ok=True)
                drive(bid, keys, ms, out_file)
                time.sleep(0.8)
                got = read_text(out_file)
                if expect is not None and "|" in expect and app.startswith("swing"):
                    got = f"{got}|{read_text(pathlib.Path(str(out_file) + '.title')) or ''}"
                underline = used_underline(app, out_file, name)
                r.update({"final": got, "pass": got == expect and not underline,
                          "shot": shot(f"{app}{'-' + tag if tag else ''}-{name}")})
                if underline:
                    r["underline"] = underline
                r.update(ime_seen(mark, None if app.startswith("swing") else bid))
                if app.startswith("chrome"):
                    r.update(web_flash(mark))
                    if name in FLASH_NAMES and r["raw_flash"] and tag != "nosettle":
                        r["pass"] = False
                        r["info"] = f"chữ thô ra trang {r['raw_flash']} lần rồi mới được sửa"
                if app == "swinghelper":
                    # Phím nào cũng phải đi đường thay chữ qua trợ thủ (không phím nào soạn bằng marked text).
                    lines = [l for l in log_since(mark).splitlines() if " phím " in l]
                    r["helper_keys"] = sum("trợ thủ Java" in l for l in lines)
                    if any("soạn (marked)" in l for l in lines):
                        r["pass"] = False
                        r["info"] = "có phím soạn bằng marked text"
                if got != expect or (app.startswith("chrome") and r.get("raw_flash") and name in FLASH_NAMES):
                    r["trace"] = ime_trace(mark)
                    if app.startswith("chrome"):
                        r["session"] = [l.split(" ", 1)[-1][:200] for l in log_since(mark).splitlines()
                                        if "session:" in l or "hỏi đồng bộ" in l][:80]
            except Exception as e:  # noqa: BLE001
                r["error"] = str(e)
                shot(f"{app}-{name}-error")
            results.append(r)
            print(f"{app}/{name}", json.dumps(r, ensure_ascii=False), flush=True)
        if app == "field":
            results += run_race(bid, out_file, ready)
    finally:
        ev = pathlib.Path(str(out_file) + ".events")
        suffix = f"-{tag}" if tag else ""
        if ev.exists():
            shutil.copy(ev, OUT / "logs" / f"{app}{suffix}-events.log")
        at = pathlib.Path(str(out_file) + ".attrs")
        if at.exists():
            shutil.copy(at, OUT / "logs" / f"{app}{suffix}-attrs.log")
            # Ô nhận phần đang soạn kèm thuộc tính gì (gộp các dòng giống nhau, bỏ vị trí).
            seen = sorted({re.sub(r"\[\d+,\d+\] ", "", l) for l in at.read_text(encoding="utf-8", errors="replace").splitlines() if l})
            for r in results:
                r["info"] = "ô nhận: " + " | ".join(seen)[:300]
        if proc:
            proc.terminate()
        elif app.startswith("chrome"):
            sh(["pkill", "-f", "chrome-profile"])
        else:
            sh(["pkill", "-f", str(FIELD_APP / "Contents/MacOS/field")])
        if web:
            web.close()
        time.sleep(1)
    return results


VSCODE = "/Applications/Visual Studio Code.app"
VSCODE_ID = "com.microsoft.VSCode"


def run_vscode(only=None, tag=None):
    """VS Code thật (ô soạn thảo dùng EditContext): gõ vào một file văn bản, đọc lại qua file (tự lưu sau 0,2 s)."""
    app = "vscode"
    if not pathlib.Path(VSCODE).exists():
        return [{"terminal": app, "test": "-", "error": "chưa cài VS Code"}]
    sh(["xattr", "-dr", "com.apple.quarantine", VSCODE])
    profile = L / "vscode-profile"
    (profile / "User").mkdir(parents=True, exist_ok=True)
    (profile / "User" / "settings.json").write_text(json.dumps({
        "files.autoSave": "afterDelay", "files.autoSaveDelay": 200, "workbench.startupEditor": "none",
        "security.workspace.trust.enabled": False, "telemetry.telemetryLevel": "off", "update.mode": "none",
        "editor.quickSuggestions": {"other": "off", "comments": "off", "strings": "off"},
        "editor.wordBasedSuggestions": "off", "editor.acceptSuggestionOnEnter": "off", "editor.autoClosingBrackets": "never",
        "editor.autoClosingQuotes": "never", "chat.commandCenter.enabled": False, "window.restoreWindows": "none",
        "workbench.tips.enabled": False, "extensions.ignoreRecommendations": True, "files.insertFinalNewline": False,
        "window.commandCenter": False, "workbench.secondarySideBar.defaultVisibility": "hidden",
    }))
    out_file = L / "vscode.txt"
    out_file.write_text("")
    sh(["open", "-na", VSCODE, "--args", f"--user-data-dir={profile}", "--disable-extensions", "--skip-welcome",
        "--skip-release-notes", "--disable-workspace-trust", "--new-window", str(out_file)])
    results = []
    try:
        for _ in range(120):
            if front() == VSCODE_ID:
                break
            time.sleep(0.5)
        else:
            shot("vscode-not-ready")
            return [{"terminal": app, "test": "-", "error": f"VS Code không ra phía trước (front={front()})"}]
        time.sleep(10)
        shot("vscode-opened")
        bid = VSCODE_ID

        def clear():
            for attempt in range(6):
                drv(bid, "{CMDA}{BS}", 60)
                for _ in range(40):
                    if read_text(out_file) == "":
                        return
                    time.sleep(0.05)
            raise RuntimeError(f"không xoá được ô VS Code (còn {read_text(out_file)!r})")

        configure("vni", "auto")
        ensure_mode(bid, "vi")
        drv(bid, "khoi dong ", 60)
        time.sleep(2)
        clear()
        for name, method, keys, expect, ms in [t for t in WEB_EDIT_TESTS if not only or t[0] in only]:
            r = {"terminal": app, "style": "-", "test": name, "expect": expect}
            try:
                if front() != VSCODE_ID:
                    raise RuntimeError(f"VS Code không ở phía trước (front={front()})")
                configure(method, "auto")
                ensure_mode(bid, "vi")
                clear()
                time.sleep(1.2)                     # ngừng gõ quá 1 s: từ đầu của bài bắt đầu như sau một lúc nghỉ
                mark = log_mark()
                drv(bid, keys, ms)
                time.sleep(1.2)
                got = read_text(out_file)
                r.update({"final": got, "pass": got == expect, "shot": shot(f"{app}{'-' + tag if tag else ''}-{name}")})
                r.update(ime_seen(mark, bid))
                r.update(web_flash(mark))
                flashed = name in FLASH_NAMES and r["raw_flash"]
                if flashed and tag != "nosettle":
                    r["pass"] = False
                    r["info"] = f"chữ thô ra trang {r['raw_flash']} lần rồi mới được sửa"
                if got != expect or flashed:
                    r["trace"] = [l[:200] for l in log_since(mark).splitlines()
                                  if "session:" in l or " phím " in l or "hỏi đồng bộ" in l][:100]
            except Exception as e:  # noqa: BLE001
                r["error"] = str(e)
                shot(f"{app}-{name}-error")
            results.append(r)
            print(f"{app}/{name}", json.dumps(r, ensure_ascii=False), flush=True)
    finally:
        sh(["pkill", "-f", "vscode-profile"])
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
    sh([DRV, "-", "20", "{TAPCTRL}{IS:en}"])
    check("start-en", "en")
    for app in ["/System/Applications/TextEdit.app", "/System/Library/CoreServices/Finder.app", term[1]]:
        sh(["open", "-a", app]); check("switch-" + pathlib.Path(app).stem, "en")
    # Ô mật khẩu: secure input bật, hệ thống chuyển sang ABC; rời ô mật khẩu thì hệ thống chọn lại GTV ở chế độ
    # chính "vi" -> GTV giữ "en"
    sh([DRV, "-", "20", "{SECURE:on}{IS:abc}{WAIT800}{SECURE:off}{IS:vi}"]); check("password-return-keeps-en", "en")
    # Người dùng tự chọn ABC rồi tự chọn "Tiếng Việt (GTV)" trong menu bộ gõ -> theo
    sh([DRV, "-", "20", "{TAPCTRL}{IS:abc}{WAIT1000}{TAPCTRL}{IS:vi}"]); check("user-abc-then-vi", "vi")
    # Chiều ngược lại: đang "vi", từ ABC chọn "English (GTV)" -> theo
    sh([DRV, "-", "20", "{TAPCTRL}{IS:abc}{WAIT1000}{TAPCTRL}{IS:en}"]); check("user-abc-then-en", "en")
    # Người dùng tự đổi (không đổi ứng dụng): theo
    time.sleep(1.0)
    sh([DRV, "-", "20", "{TAPCTRL}{IS:vi}"]); check("user-switch-to-vi", "vi")
    for app in ["/System/Applications/TextEdit.app", term[1]]:
        sh(["open", "-a", app]); check("switch-vi-" + pathlib.Path(app).stem, "vi")
    # Đổi ứng dụng rồi 0,3 s sau người dùng chọn "English (GTV)" (⌃Space, 🌐…) -> theo, không bị đảo lại
    sh(["open", "-a", "/System/Applications/TextEdit.app"]); time.sleep(0.3)
    sh([DRV, "-", "20", "{TAPCTRL}{IS:en}"]); check("user-switch-right-after-app-switch", "en")
    # Lỗi người dùng gặp (macOS 27, Burp): vừa đổi ứng dụng xong bấm ⇧ / ⌘ / ⌥ (gõ chữ hoa, ⌘V, ⌥⌫…) đúng lúc hệ thống chọn
    # lại chế độ nó nhớ cho ứng dụng đó — GTV coi là người dùng chọn, gõ ra số / không dấu. Phím đó không phải thao tác chọn
    # bộ gõ: GTV phải giữ chế độ.
    def switch_then(app, bid, keys):
        """Đổi sang `app`, và ngay khi GTV được gắn vào ô của nó (dòng activateServer trong log) thì gõ `keys` — trong
        khoảng GTV còn coi lần chọn chế độ là của hệ thống (0,6 s sau khi gắn)."""
        m = log_mark()
        sh(["open", "-a", app])
        for _ in range(400):
            if f"activateServer {bid}" in log_since(m):
                break
            time.sleep(0.01)
        sh([DRV, "-", "5", keys])
    time.sleep(1.0)
    sh([DRV, "-", "20", "{TAPCTRL}{IS:vi}"]); check("back-to-vi", "vi")
    switch_then(term[1], term[0], "{TAPSHIFT}{IS:en}"); check("shift-after-app-switch-keeps-vi", "vi")
    switch_then("/System/Applications/TextEdit.app", "com.apple.TextEdit", "{TAB}{IS:en}")
    check("tab-after-app-switch-keeps-vi", "vi")
    # Đối chứng: cùng lúc đó mà người dùng bấm ⌃ (⌃Space) thì là họ chọn — theo.
    switch_then(term[1], term[0], "{TAPCTRL}{IS:en}"); check("ctrl-after-app-switch-follows", "en")
    # Từ ABC chọn lại một chế độ của GTV, lặp nhiều lần: macOS gắn GTV vào ô rồi mới báo chế độ người dùng chọn — GTV không
    # được chọn đè chế độ cũ, lời báo cho lần GTV tự chọn không phải người dùng chọn (lab 42055281996, có lúc mới gặp).
    for i in range(int(os.environ.get("MODES_REPEAT", "3"))):
        for target in ("vi", "en"):
            sh([DRV, "-", "20", "{TAPCTRL}{IS:abc}{WAIT1000}{TAPCTRL}{IS:" + target + "}"])
            check(f"user-abc-then-{target}-{i + 1}", target)
    out += run_hotkey_modes(term, check, out)
    sh(["pkill", "-x", "TextEdit"])
    return out


def run_hotkey_modes(term, check, checked):
    """Lỗi người dùng gặp ở bản gốc: đổi V/E bằng phím tắt ⌘⇧ của GTV, đổi ứng dụng rồi quay lại — chế độ tự nhảy. Đổi bằng ⌘⇧
    thật rồi đổi qua lại các ứng dụng: chế độ phải giữ nguyên, và không ô nào phát lại chế độ cũ (dòng "giữ chế độ" trong log:
    lần GTV phải chọn lại chế độ của nó).
    (Lab 44067817184 đã thử đổi chế độ qua `IMKTextInput.selectMode` kèm TISSelectInputSource: hai đường chọn chồng nhau làm hệ
    thống báo lại chế độ cũ ngay sau phím tắt, đổi sang tiếng Anh không ăn — bỏ. Chỉ TISSelectInputSource: 0 lần phát lại.)"""
    apps = ["/System/Applications/TextEdit.app", term[1], "/System/Library/CoreServices/Finder.app", term[1]]
    out = []
    sh(["open", "-a", term[1]])
    time.sleep(1.5)
    mark = log_mark()
    for i in range(2):
        for target in ("en", "vi"):
            for _ in range(3):
                if current_source().endswith("." + target):
                    break
                sh([DRV, "-", "20", "{TOGGLE}"])
                time.sleep(0.4)
            check(f"hotkey-{target}-{i + 1}", target)
            for app in apps:
                sh(["open", "-a", app])
                check(f"hotkey-{target}-{i + 1}-to-{pathlib.Path(app).stem}", target)
    log = log_since(mark)
    replays = log.count("giữ chế độ")
    (OUT / "logs" / "modes-hotkey.log").write_text(
        "\n".join(l for l in log.splitlines() if re.search(r"setValue|bộ gõ đổi|giữ chế độ|chế độ ->|toggle|activateServer", l)))
    out.append({"terminal": "modes", "style": "-", "test": "hotkey-replays", "expect": "0", "final": str(replays),
                "pass": replays == 0, "info": "số lần ô phát lại chế độ cũ"})
    print("modes", "hotkey-replays", replays, flush=True)
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

    # Ứng dụng thường cũng chạy từng chế độ bộ đếm: ô web trên macOS 27 khác macOS 26.
    for counter_mode in counter_modes:
        suffix = set_counter_mode(counter_mode)
        for app in os.environ.get("APPS", "field blind swing chrome").split():
            try:
                part = run_vscode() if app == "vscode" else run_app_suite(app)
            except Exception as e:  # noqa: BLE001
                part = [{"terminal": app, "test": "-", "error": str(e)}]
                shot(f"{app}{suffix}-fatal")
            for r in part:
                r["terminal"] = r.get("terminal", app) + suffix
            results += part

    # Đối chứng cho các bài "không chữ thô ra trang": cùng bài đó với bộ gõ KHÔNG hỏi trang đồng bộ (cách cũ) — phải thấy chữ thô
    # ra trang (`raw_flash` > 0) thì bài thử mới thật sự bắt được lỗi người dùng báo. Chỉ ghi lại, không chấm.
    for app in os.environ.get("NOSETTLE_APPS", "").split():
        set_counter_mode(counter_modes[0])
        set_settle(False)
        try:
            part = run_vscode(only=FLASH_NAMES, tag="nosettle") if app == "vscode" \
                else run_app_suite(app, only=FLASH_NAMES, tag="nosettle")
        except Exception as e:  # noqa: BLE001
            part = [{"terminal": app, "test": "-", "error": str(e)}]
        finally:
            set_settle(True)
        for r in part:
            r["terminal"] = r.get("terminal", app) + "-nosettle"
            r["control"] = True
            r["expect_final"] = r.get("expect")
            r["expect"] = None
            r.pop("pass", None)
        results += part

    # Đo riêng câu hỏi "ký tự ở điểm này": hỏi nó TRƯỚC câu hỏi chỗ con trỏ. Ở trang chậm (chromeslow) câu nào chờ trang thì mất
    # cỡ 100 ms — biết chắc câu nào là rào thật. Chấm như thường.
    for app in os.environ.get("INDEXFIRST_APPS", "").split():
        set_counter_mode(counter_modes[0])
        set_settle(True, probe="index-first")
        try:
            part = run_vscode(only=FLASH_NAMES, tag="idx") if app == "vscode" else run_app_suite(app, tag="idx")
        except Exception as e:  # noqa: BLE001
            part = [{"terminal": app, "test": "-", "error": str(e)}]
        finally:
            set_settle(True)
        for r in part:
            r["terminal"] = r.get("terminal", app) + "-idx"
        results += part

    # Đo: bộ gõ gắn thuộc tính kiểu nào cho phần đang soạn thì ô nhận được gì (bản Debug, `labComposing`). "plain" = chuỗi thường.
    d = "com.gtv.inputmethod.GTV"
    for recipe in os.environ.get("COMPOSE_RECIPES", "").split():
        if recipe == "plain":
            sh(["defaults", "delete", d, "labComposing"])
        else:
            sh(["defaults", "write", d, "labComposing", "-string", recipe])
        sh(["notifyutil", "-p", "com.gtv.lab.reload"])
        time.sleep(0.4)
        for app in os.environ.get("COMPOSE_APPS", "blind swing").split():
            try:
                part = run_app_suite(app, only={"vni-punct"}, tag=recipe)
            except Exception as e:  # noqa: BLE001
                part = [{"terminal": app, "test": "-", "error": str(e)}]
            for r in part:
                r["terminal"] = f"{r.get('terminal', app)}@{recipe}"
            results += part
    sh(["defaults", "delete", d, "labComposing"])
    sh(["notifyutil", "-p", "com.gtv.lab.reload"])

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
        ok = "lỗi" if "error" in r else "ghi" if r.get("control") else ("✅" if r.get("pass") else "❌")
        split = f"{r.get('edits_split', '')}/{r.get('edits', '')}" if "edits" in r else ""
        note = r.get("error", "") or ("mong đợi: " + r["expect"] if not r.get("pass") and r.get("expect") is not None
                                      and r.get("final") != r["expect"] else "")
        if r.get("underline"):
            note = (note + "; " if note else "") + "ô vẽ gạch chân"
        if r.get("info"):
            note = (note + "; " if note else "") + r["info"]
        rows.append(f"| {r['terminal']} | {r.get('style', '')} | {r['test']} | {ok} | `{r.get('final', '')}` | {split} | {note} |")
    md = "\n".join(rows)
    (OUT / "summary.md").write_text(md + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## IME Lab\n\n" + md + "\n")
    print(md)


if __name__ == "__main__":
    main()
