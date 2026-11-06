#!/usr/bin/env python3
"""Bộ test cục bộ trên máy người dùng: gõ vào app Swing (JRE của Burp) / Burp, so kết quả, đo độ mượt."""
import subprocess, time, pathlib, sys, os, json, re
L = pathlib.Path('/Volumes/HDD_2/Downloads/gtv-work/local')
J = '/Applications/Burp Suite.app/Contents/Resources/jre.bundle/Contents/Home/bin/java'
LOG = pathlib.Path.home() / 'Library/Logs/GTV-debug.log'
OUT = pathlib.Path('/private/tmp/claude-501/-Users-eejay-Downloads-trae-gtv/33f19d35-e26f-415a-ae8c-4ff9749a5b00/scratchpad/local/swing.txt')
SWING = None

def sh(*a, **k): return subprocess.run([str(x) for x in a], capture_output=True, text=True, **k)
def front(): return sh(L/'front').stdout.strip()
def log_mark(): return LOG.stat().st_size if LOG.exists() else 0
def log_since(m):
    if not LOG.exists(): return ''
    with open(LOG, 'rb') as f: f.seek(m); return f.read().decode('utf-8', 'replace')

def set_method(m):  # 0 telex, 1 vni
    sh('defaults', 'write', 'com.gtv.inputmethod.GTV', 'method', '-int', str(m))
    sh('notifyutil', '-p', 'com.gtv.lab.reload'); time.sleep(0.3)

def start_swing():
    for p in [OUT, pathlib.Path(str(OUT)+'.ready')]: p.unlink(missing_ok=True)
    global SWING
    proc = subprocess.Popen([J, str(L/'SwingFieldT.java'), str(OUT)], stdout=open(str(OUT)+'.log','w'), stderr=subprocess.STDOUT)
    SWING = proc
    for _ in range(200):
        if pathlib.Path(str(OUT)+'.ready').exists(): break
        time.sleep(0.1)
    time.sleep(0.8)
    return proc

def clear():
    pathlib.Path(str(OUT)+'.clear').touch()
    for _ in range(50):
        if not pathlib.Path(str(OUT)+'.clear').exists() and OUT.read_text() == '': break
        time.sleep(0.05)
    tl = pathlib.Path(str(OUT)+'.timeline'); tl.unlink(missing_ok=True)
    time.sleep(0.3)

def type_keys(bid, keys, ms):
    r = sh(L/'drv', bid, ms, keys)
    if r.returncode != 0: raise RuntimeError('driver: ' + r.stderr.strip())

def timeline():
    tl = pathlib.Path(str(OUT)+'.timeline')
    if not tl.exists(): return []
    rows = []
    for line in tl.read_text().splitlines():
        t, _, rest = line.partition(' ')
        parts = rest.split('\u0001')
        rows.append((int(t), parts[0].replace('\\n', '\n'), int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else -1))
    return rows

def ensure_front(bid):
    for _ in range(20):
        if front() == bid: return True
        if SWING is not None: sh(L/'activate', SWING.pid)
        time.sleep(0.3)
    return front() == bid

def settle(timeout=5.0):
    """Chờ ô thôi đổi (ứng dụng xử lý hết phím đang xếp hàng)."""
    tl = pathlib.Path(str(OUT)+'.timeline'); last = None; stable = 0; t = time.time()
    while time.time() - t < timeout:
        cur = (tl.stat().st_size if tl.exists() else 0, OUT.read_text() if OUT.exists() else '')
        stable = stable + 1 if cur == last else 0
        last = cur
        if stable >= 6: return
        time.sleep(0.05)

def run_case(bid, name, method, keys, expect, ms):
    if not ensure_front(bid): raise RuntimeError('không đưa được ' + bid + ' lên trước (đang là ' + front() + ')')
    set_method(method)
    type_keys(bid, '{ESC}', 30)          # ngắt từ đang gõ dở của bài trước (ô sắp bị xoá bằng code, bộ gõ không thấy)
    clear(); settle()
    mark = log_mark()
    t0 = time.time()
    type_keys(bid, keys, ms)
    settle()
    got = OUT.read_text()
    tl = timeline()
    lg = log_since(mark)
    routes = set(re.findall(r'\[([^\]]+)\]: ', lg))
    marked = 'gạch chân' in ' '.join(routes)
    posts = len(re.findall(r'phím giả: gửi', lg))
    deferred = len(re.findall(r'hoãn lần sửa', lg))
    ok = expect is None or got == expect
    return dict(name=name, ok=ok, got=got, expect=expect, routes=sorted(routes), marked=marked, posts=posts,
                deferred=deferred, changes=len(tl))

if __name__ == '__main__':
    pass

BURP = 'com.install4j.6592-1155-2163-3973.70'
BURP_PID = None

def burp_text():
    r = sh(L/'axval', BURP_PID)
    return r.stdout if r.returncode == 0 else None

def burp_settle(timeout=5.0):
    last = None; stable = 0; t = time.time()
    while time.time() - t < timeout:
        cur = burp_text()
        stable = stable + 1 if cur == last else 0
        last = cur
        if stable >= 5: return cur
        time.sleep(0.06)
    return last

def run_burp(name, method, keys, expect, ms):
    if front() != BURP: raise RuntimeError('Burp không ở trước (' + front() + ')')
    if sh(L/'axval', BURP_PID, 'role').stdout.split()[:1] != ['AXTextArea']: raise RuntimeError('focus không ở ô soạn thảo')
    set_method(method)
    type_keys(BURP, '{ESC}{CMDA}{BS}', 40)
    burp_settle()
    mark = log_mark()
    type_keys(BURP, keys, ms)
    got = burp_settle()
    lg = log_since(mark)
    routes = set(re.findall(r'\[([^\]]+)\]: ', lg))
    return dict(name=name, ok=(expect is None or got == expect), got=got, expect=expect, routes=sorted(routes),
                marked='gạch chân' in ' '.join(routes), posts=len(re.findall(r'phím giả: gửi', lg)),
                deferred=len(re.findall(r'hoãn lần sửa', lg)))
