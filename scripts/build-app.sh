#!/bin/bash
# 构建 CourseRec.app（无 Xcode 路线：swift build + 手工组装 bundle + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
MEDIAMTX_VERSION="1.18.2"
MACHINE_ARCH="$(uname -m)"
case "$MACHINE_ARCH" in
    arm64)
        MEDIAMTX_ARCH="arm64"
        MEDIAMTX_SHA256="6a9273ae22a9d0ba85d00d03fdd1b13b9eeaf129ea8b90999ec746367f20449a"
        ;;
    x86_64)
        MEDIAMTX_ARCH="amd64"
        MEDIAMTX_SHA256="d0f9b2f67da6bbed0b8e01d6baea07d9e5e9b2b617d6c421fc9b1a98d232bfca"
        ;;
    *)
        echo "不支持的 Mac 架构：$MACHINE_ARCH"
        exit 1
        ;;
esac
MEDIAMTX_CACHE=".build/tools/mediamtx/v$MEDIAMTX_VERSION/$MEDIAMTX_ARCH/mediamtx"

if [ ! -x "$MEDIAMTX_CACHE" ]; then
    echo "▶ 下载内置 RTMP 服务 MediaMTX v$MEDIAMTX_VERSION ($MEDIAMTX_ARCH)"
    DOWNLOAD_DIR="$(mktemp -d)"
    trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
    ARCHIVE="mediamtx_v${MEDIAMTX_VERSION}_darwin_${MEDIAMTX_ARCH}.tar.gz"
    curl -fL --retry 3 \
        "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/${ARCHIVE}" \
        -o "$DOWNLOAD_DIR/$ARCHIVE"
    ACTUAL_SHA256="$(shasum -a 256 "$DOWNLOAD_DIR/$ARCHIVE" | awk '{print $1}')"
    if [ "$ACTUAL_SHA256" != "$MEDIAMTX_SHA256" ]; then
        echo "MediaMTX 校验失败：期望 $MEDIAMTX_SHA256，实际 $ACTUAL_SHA256"
        exit 1
    fi
    tar -xzf "$DOWNLOAD_DIR/$ARCHIVE" -C "$DOWNLOAD_DIR" mediamtx
    mkdir -p "$(dirname "$MEDIAMTX_CACHE")"
    install -m 755 "$DOWNLOAD_DIR/mediamtx" "$MEDIAMTX_CACHE"
fi

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"

APP="CourseRec.app"
echo "▶ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/CourseRec" "$APP/Contents/MacOS/CourseRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Support "$APP/Contents/Resources/Support"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$MEDIAMTX_CACHE" "$APP/Contents/Resources/mediamtx"

echo "▶ 签名（稳定自签名证书，TCC 授权跨构建保持）"
IDENTITY="CourseRec Dev"
if security find-certificate -c "$IDENTITY" login.keychain-db >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/mediamtx"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "  ⚠️ 未找到 $IDENTITY 证书，退回 ad-hoc 签名（每次构建权限会失效）"
    codesign --force --sign - "$APP/Contents/Resources/mediamtx"
    codesign --force --sign - "$APP"
fi

echo "✅ 构建完成: $(pwd)/$APP"
echo "   运行: open $APP"
