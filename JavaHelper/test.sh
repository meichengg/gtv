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
"$JAVAC" --release 11 -Xlint:all -Werror -encoding UTF-8 -d "$WORK" src/gtv/helper/*.java test/gtv/helper/*.java
"$JAVA" -Djava.awt.headless=true -Dfile.encoding=UTF-8 -cp "$WORK" gtv.helper.HelperTest
if [ "${1:-}" = "--awt" ]; then
    "$JAVA" -Dapple.awt.UIElement=true -Dfile.encoding=UTF-8 -cp "$WORK" gtv.helper.PipelineTest
fi
