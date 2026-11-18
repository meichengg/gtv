#!/bin/bash
# Bài thử của trợ thủ Java.
#   JavaHelper/test.sh         không cần màn hình (logic thay chữ trên JTextArea / JTextField / JTextPane)
#   JavaHelper/test.sh --awt   thêm đường đi thật của AWT (cần phiên đồ hoạ; không mở cửa sổ, không hiện trên Dock)
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
