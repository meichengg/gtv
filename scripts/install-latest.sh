#!/bin/bash
# Tải bản GTV build mới nhất (GitHub Releases, do workflow Release tạo khi push lên main) rồi cài.
# Không cần đăng xuất: GTV.app tự cập nhật bộ gõ đang chạy, đăng ký lại và chọn GTV
# (xem Sources/GTVLauncher/main.swift). Cần `gh` đã đăng nhập.
#   scripts/install-latest.sh              # repo mặc định
#   scripts/install-latest.sh owner/repo
#
# Bộ gõ thấy mọi phím gõ: chỉ cài DMG có chứng thực build (artifact attestation) do workflow Release của chính repo đó
# tạo từ nhánh main (`gh attestation verify`), không tin riêng file trong release (ai có quyền ghi repo cũng thay được).
# Bản phát hành cũ chưa có chứng thực: GTV_ALLOW_UNVERIFIED=1 scripts/install-latest.sh
set -euo pipefail

REPO="${1:-meichengg/gtv}"
TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() {
    hdiutil detach -quiet "$MNT" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName)"
# Mỗi lần build trên main thêm một DMG tên riêng (theo số build) vào release của phiên bản: lấy DMG tải lên sau cùng.
NAME="$(gh release view "$TAG" --repo "$REPO" --json assets \
    -q '[.assets[] | select(.name | test("^GTV-.*\\.dmg$"))] | sort_by(.createdAt) | last | .name // empty')"
if [ -z "$NAME" ]; then
    echo "Release $TAG của $REPO không có file GTV-*.dmg" >&2
    exit 1
fi
echo "Bản mới nhất: $TAG ($NAME)"
gh release download "$TAG" --repo "$REPO" --pattern "$NAME" --dir "$TMP"
DMG="$TMP/$NAME"

if ! gh attestation verify "$DMG" --repo "$REPO" --signer-workflow "$REPO/.github/workflows/release.yml" \
        --source-ref refs/heads/main --deny-self-hosted-runners >/dev/null; then
    if [ "${GTV_ALLOW_UNVERIFIED:-}" = 1 ]; then
        echo "Cảnh báo: $NAME không có chứng thực build hợp lệ, vẫn cài vì GTV_ALLOW_UNVERIFIED=1." >&2
    else
        echo "Không cài: không kiểm chứng được $NAME là bản do workflow Release của $REPO build." >&2
        echo "Bản phát hành trước khi có chứng thực: chạy lại với GTV_ALLOW_UNVERIFIED=1 nếu chắc chắn." >&2
        exit 1
    fi
fi

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
