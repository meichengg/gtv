#!/bin/bash
# Build GTVInput Debug, ký bằng chứng chỉ của fork (giữ quyền Trợ năng), thay vào bộ gõ đang cài, khởi động lại.
set -euo pipefail
L=/Volumes/HDD_2/Downloads/gtv-work/local; S=$L/sign; KC="$S/sign.keychain-db"
/Volumes/HDD_2/Downloads/gtv-work/devbuild/build.sh debug | tail -1
security unlock-keychain -p "$(cat $S/kpw)" "$KC"
I="$HOME/Library/Input Methods/GTVInput.app"
rm -rf "$L/stage"; mkdir -p "$L/stage"; ditto "$I" "$L/stage/GTVInput.app"
cp /Volumes/HDD_2/Downloads/gtv-work/devbuild/.build/out/Products/Debug/GTVInput "$L/stage/GTVInput.app/Contents/MacOS/GTVInput"
ID=$(security find-identity -p codesigning "$KC" | awk '/GTV Code Signing/ {print $2; exit}')
codesign --force --sign "$ID" --keychain "$KC" --timestamp=none --entitlements "$L/ent.plist" "$L/stage/GTVInput.app" 2>&1 | grep -v "replacing existing" || true
codesign --verify --strict "$L/stage/GTVInput.app"
ditto "$L/stage/GTVInput.app/Contents" "$I/Contents"
pkill -x GTVInput || true; sleep 1; open -g "$I"; sleep 3
grep "khởi động" ~/Library/Logs/GTV-debug.log | tail -1
