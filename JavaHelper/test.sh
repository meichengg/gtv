#!/bin/bash
# Bài thử của trợ thủ Java.
#   JavaHelper/test.sh         không cần màn hình (logic thay chữ trên JTextArea / JTextField / JTextPane)
#   JavaHelper/test.sh --awt   thêm đường đi thật của AWT (cần phiên đồ hoạ; không mở cửa sổ, không hiện trên Dock)
# Trên macOS có swiftc: thêm bài bộ gõ tự nạp trợ thủ vào máy ảo đang chạy (mã Swift của bộ gõ + máy ảo thật).
set -euo pipefail
cd "$(dirname "$0")"
JAVAC="${GTV_JAVAC:-$(command -v javac)}"
JAVA="$(dirname "$JAVAC")/java"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
./compile.sh "$JAVAC" "$WORK"
"$JAVAC" --release 11 -Xlint:all -Werror -encoding UTF-8 -cp "$WORK" -d "$WORK" test/gtv/helper/*.java
# Lớp điểm vào phải nạp được trên Java 8 (class file bản 52), các lớp khác là Java 11 (bản 55).
major() { od -An -tu1 -j7 -N1 "$1" | tr -d ' '; }
if [ "$(major "$WORK/gtv/helper/Agent.class")" != "52" ] || [ "$(major "$WORK/gtv/helper/Bridge.class")" != "55" ]; then
    echo "HỎNG phiên bản class: Agent=$(major "$WORK/gtv/helper/Agent.class") (cần 52), Bridge=$(major "$WORK/gtv/helper/Bridge.class") (cần 55)"
    exit 1
fi
echo "ok   phiên bản class: Agent 52 (Java 8), các lớp khác 55 (Java 11)"
"$JAVA" -Djava.awt.headless=true -Dfile.encoding=UTF-8 -cp "$WORK" gtv.helper.HelperTest
if [ "${1:-}" = "--awt" ]; then
    "$JAVA" -Dapple.awt.UIElement=true -Dfile.encoding=UTF-8 -cp "$WORK" gtv.helper.PipelineTest
fi

# Bộ gõ tự nạp trợ thủ vào máy ảo đang chạy (Sources/GTVInput/JavaAttach.swift): mỗi bài một máy ảo không có -javaagent.
if [ "$(uname)" != Darwin ] || ! command -v swiftc >/dev/null; then
    echo "bỏ qua bài tự nạp vào máy ảo đang chạy (cần macOS và swiftc)"
    exit 0
fi
swiftc -O -o "$WORK/attach" ../Sources/GTVInput/JavaAttach.swift ../Sources/VietEngine/JavaWire.swift test/attach/main.swift
mkdir -p "$WORK/jar/META-INF"
cp -R "$WORK/gtv" "$WORK/jar/" && cp MANIFEST.MF "$WORK/jar/META-INF/MANIFEST.MF"
(cd "$WORK/jar" && zip -q -X "$WORK/helper.jar" META-INF/MANIFEST.MF && zip -q -X -r "$WORK/helper.jar" gtv)
FAILED=0
# attach_case <tên> <kết quả phải có: loaded|unreachable|failed> <máy ảo phải có trợ thủ: yes|no> [tham số máy ảo…]
attach_case() {
    local name="$1" want="$2" agent="$3"; shift 3
    local out="$WORK/target.out"
    : > "$out"
    "$JAVA" "$@" -cp "$WORK" gtv.helper.AttachTarget > "$out" 2> "$WORK/target.err" &
    local pid=$! i
    for i in $(seq 100); do grep -q '^ready' "$out" && break; sleep 0.1; done
    local got; got="$("$WORK/attach" "$pid" "$WORK/helper.jar")"
    for i in $(seq 40); do grep -q '^agent' "$out" && break; [ "$agent" = no ] && [ "$i" -ge 5 ] && break; sleep 0.1; done
    local has=no alive=no
    grep -q '^agent' "$out" && has=yes
    kill -0 "$pid" 2>/dev/null && alive=yes
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    rm -f "$(getconf DARWIN_USER_TEMP_DIR).java_pid$pid"       # máy ảo -Xrs bị dừng không tự dọn socket của nó
    if [ "${got%%:*}" = "$want" ] && [ "$has" = "$agent" ] && [ "$alive" = yes ]; then
        echo "ok   tự nạp: $name → $got"
    else
        echo "HỎNG tự nạp: $name → '$got', trợ thủ trong máy ảo: $has (cần $agent), máy ảo còn chạy: $alive"
        FAILED=1
    fi
}
attach_case "máy ảo thường" loaded yes
# -Xrs: máy ảo không bắt SIGQUIT (tín hiệu đó sẽ kết thúc nó) nhưng mở cổng attach từ lúc khởi động — nạp không cần tín hiệu.
attach_case "máy ảo -Xrs" loaded yes -Xrs
# Tắt cơ chế attach: máy ảo chỉ in danh sách luồng; bộ gõ thôi sau thời gian chờ, máy ảo chạy tiếp.
attach_case "máy ảo tắt cơ chế attach" unreachable no -XX:+DisableAttachMechanism
# Java 21 trở lên: tắt việc nạp agent lúc chạy (mặc định của một bản Java sau này) — máy ảo từ chối, chạy tiếp.
if "$JAVA" -XX:-EnableDynamicAgentLoading -version >/dev/null 2>&1; then
    attach_case "máy ảo không cho nạp agent lúc chạy" failed no -XX:-EnableDynamicAgentLoading
fi
exit "$FAILED"
