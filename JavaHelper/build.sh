#!/bin/bash
# Dựng gtv-java-helper.jar (trợ thủ Java của GTV, xem src/gtv/helper/Agent.java).
#   JavaHelper/build.sh <file .jar đầu ra>
# Cần javac 11 trở lên. Không tìm thấy thì chép bản dựng sẵn (prebuilt/) — bản đó phải được dựng lại mỗi khi sửa mã nguồn
# (JavaHelper/build.sh JavaHelper/prebuilt/gtv-java-helper.jar).
# Lớp điểm vào (Agent) dịch cho Java 8 để máy ảo Java 8–10 có dòng -javaagent vẫn khởi động được (trợ thủ tự thôi ở đó);
# các lớp còn lại cần Java 11. Xem compile.sh.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?thiếu đường dẫn file .jar đầu ra}"
case "$OUT" in /*) ;; *) OUT="$OLDPWD/$OUT" ;; esac

find_javac() {
    local c
    for c in "${JAVA_HOME:-}" "${JAVA_HOME_21_arm64:-}" "${JAVA_HOME_21_X64:-}" "${JAVA_HOME_17_arm64:-}" \
             "${JAVA_HOME_17_X64:-}" "${JAVA_HOME_25_arm64:-}" "${JAVA_HOME_11_arm64:-}" "${JAVA_HOME_11_X64:-}"; do
        if [ -n "$c" ] && [ -x "$c/bin/javac" ]; then echo "$c/bin/javac"; return; fi
    done
    if c="$(/usr/libexec/java_home -v 11+ 2>/dev/null)" && [ -x "$c/bin/javac" ]; then echo "$c/bin/javac"; return; fi
    if [ -n "${GTV_JAVAC:-}" ] && [ -x "$GTV_JAVAC" ]; then echo "$GTV_JAVAC"; return; fi
    return 1
}

mkdir -p "$(dirname "$OUT")"
if ! JAVAC="$(find_javac)"; then
    echo "warning: không có javac — dùng JavaHelper/prebuilt/gtv-java-helper.jar" >&2
    cp prebuilt/gtv-java-helper.jar "$OUT"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
./compile.sh "$JAVAC" "$WORK/classes"
mkdir -p "$WORK/classes/META-INF"
cp MANIFEST.MF "$WORK/classes/META-INF/MANIFEST.MF"
rm -f "$OUT"
# File .jar là file zip có META-INF/MANIFEST.MF ở đầu; giờ sửa file cố định để hai lần dựng cùng mã nguồn ra cùng nội dung.
(cd "$WORK/classes" && find . -exec touch -t 202601010000 {} + \
    && zip -q -X "$OUT" META-INF/MANIFEST.MF && zip -q -X -r "$OUT" gtv)
echo "$OUT"
