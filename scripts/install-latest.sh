#!/bin/bash
# Tải bản GTV build mới nhất (GitHub Releases, do workflow Release tạo khi push lên main) rồi cài.
# Không cần đăng xuất: GTV.app tự chép đè bộ gõ đang chạy, đăng ký lại và chọn GTV
# (xem Sources/GTVLauncher/main.swift). Cần `gh` đã đăng nhập (repo private).
#   scripts/install-latest.sh              # repo mặc định
#   scripts/install-latest.sh owner/repo
set -euo pipefail

REPO="${1:-meichengg/gtv}"
TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() {
    hdiutil detach -quiet "$MNT" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

gh release view --repo "$REPO" --json tagName,publishedAt \
    --template 'Bản mới nhất: {{.tagName}} (build lúc {{timefmt "02/01/2006 15:04" .publishedAt}} UTC)'
echo
gh release download --repo "$REPO" --pattern 'GTV-*.dmg' --dir "$TMP"
DMG="$(ls "$TMP"/GTV-*.dmg | head -1)"
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MNT" "$DMG"

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/GTV.app"
ditto "$MNT/GTV.app" "$DEST/GTV.app"
# Tải bằng gh thì không bị gắn cờ quarantine, xoá cho chắc để Gatekeeper không hỏi.
xattr -dr com.apple.quarantine "$DEST/GTV.app" 2>/dev/null || true

# GTV.app cài/cập nhật bộ gõ vào ~/Library/Input Methods, chọn GTV rồi tự thoát.
open "$DEST/GTV.app"
echo "Đã cài $(basename "$DMG" .dmg) vào $DEST/GTV.app"
