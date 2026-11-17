#!/bin/bash
# Bài thử của trợ thủ Java (không cần màn hình): JavaHelper/test.sh
set -euo pipefail
cd "$(dirname "$0")"
JAVAC="${GTV_JAVAC:-$(command -v javac)}"
JAVA="$(dirname "$JAVAC")/java"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$JAVAC" --release 11 -Xlint:all -Werror -encoding UTF-8 -d "$WORK" src/gtv/helper/*.java test/gtv/helper/*.java
"$JAVA" -Djava.awt.headless=true -Dfile.encoding=UTF-8 -cp "$WORK" gtv.helper.HelperTest
