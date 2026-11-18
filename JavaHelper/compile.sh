#!/bin/bash
# Dịch mã nguồn trợ thủ vào một thư mục:  JavaHelper/compile.sh <javac> <thư mục đầu ra>
# Agent (điểm vào của -javaagent) dịch cho Java 8, không phụ thuộc lớp nào khác lúc dịch (nó nạp Bridge bằng tên);
# các lớp còn lại dịch cho Java 11.
set -euo pipefail
cd "$(dirname "$0")"
JAVAC="${1:?thiếu javac}"
OUT="${2:?thiếu thư mục đầu ra}"
mkdir -p "$OUT"
# -Xlint:-options: javac mới cảnh báo "--release 8 đã lỗi thời" — với -Werror thì thành lỗi.
"$JAVAC" --release 8 -Xlint:all,-options -Werror -encoding UTF-8 -d "$OUT" src/gtv/helper/Agent.java
OTHERS=()
for f in src/gtv/helper/*.java; do
    [ "$f" = "src/gtv/helper/Agent.java" ] || OTHERS+=("$f")
done
"$JAVAC" --release 11 -Xlint:all -Werror -encoding UTF-8 -cp "$OUT" -d "$OUT" "${OTHERS[@]}"
