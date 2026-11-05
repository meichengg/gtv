#!/bin/bash
# Build build/GTV.app (Release, chạy được trên cả Apple Silicon và Intel) bằng GTV.xcodeproj.
#
# Mặc định ký ad-hoc: chạy được trên máy build. Để phát hành cho người khác, ký bằng
# chứng chỉ Developer ID:
#   DEVELOPER_ID="Developer ID Application: Ten Ban (TEAMID1234)" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

# Sinh lại project nếu có XcodeGen (project.yml là nguồn gốc).
if command -v xcodegen >/dev/null; then xcodegen -q; fi

# Số build theo thời điểm build (UTC), tăng dần qua mọi bản build kể cả cùng MARKETING_VERSION: Sparkle so CFBundleVersion
# nên mỗi lần build lại trên main đều là bản mới với máy đã cài. Dạng YYYYMMDD.HHMMSS lớn hơn mọi số build kiểu cũ
# (= MARKETING_VERSION, vd. 1.12): đừng đổi sang dạng nhỏ hơn, máy đã cài sẽ không bao giờ nhận cập nhật nữa.
# GTVBuildStamp (giây) cùng thời điểm: GTV.app không cài đè bộ gõ mới bằng bộ gõ cũ hơn (Sources/GTVLauncher).
read -r STAMP BUILD_NUMBER < <(date -u '+%s %Y%m%d.%H%M%S')

SIGN_ARGS=()
if [ -n "${DEVELOPER_ID:-}" ]; then
    TEAM="$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$DEVELOPER_ID")"
    SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS=--timestamp
               ENABLE_HARDENED_RUNTIME=YES)
fi

xcodebuild -project GTV.xcodeproj -scheme GTV -configuration Release \
    -derivedDataPath build/dd ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" GTV_BUILD_STAMP="$STAMP" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
    build -quiet

rm -rf build/GTV.app
cp -R build/dd/Build/Products/Release/GTV.app build/GTV.app

if [ -n "${DEVELOPER_ID:-}" ]; then
    # Code Sign On Copy chỉ ký lại vỏ Sparkle.framework: Installer.xpc, Downloader.xpc, Autoupdate, Updater.app bên trong
    # vẫn mang chữ ký ad-hoc của Sparkle (không Team ID, không timestamp, không hardened runtime) nên notarize từ chối.
    # Ký lại từ trong ra ngoài theo hướng dẫn của Sparkle, rồi tới bộ gõ và GTV.app (chữ ký ngoài niêm cả phần bên trong).
    sign() { codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$@"; }
    IME=build/GTV.app/Contents/Resources/GTVInput.app
    SPARKLE="$IME/Contents/Frameworks/Sparkle.framework"
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
    sign --preserve-metadata=entitlements "$IME"
    sign --preserve-metadata=entitlements build/GTV.app
fi
codesign --verify --deep --strict build/GTV.app

echo "Đã build: build/GTV.app ($BUILD_NUMBER, $(du -sh build/GTV.app | cut -f1), $(lipo -archs build/GTV.app/Contents/MacOS/GTV))"
