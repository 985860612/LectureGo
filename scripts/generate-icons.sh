#!/bin/bash
# 从同一份 LectureGo SVG 生成 macOS AppIcon.icns。
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in qlmanage magick iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "缺少图标生成工具：$tool"
        exit 1
    fi
done

SOURCE="Resources/LectureGoAppIcon.svg"
OUTPUT="Resources/AppIcon.icns"
WORK_DIR="$(mktemp -d)"
ICONSET="$WORK_DIR/AppIcon.iconset"
PREVIEW_DIR="$WORK_DIR/preview"
MASTER="$WORK_DIR/AppIcon.png"

mkdir -p "$ICONSET" "$PREVIEW_DIR"
xmllint --noout "$SOURCE"

# Quick Look 对 SVG 描边支持稳定；随后恢复圆角外透明区域。
qlmanage -t -s 1024 -o "$PREVIEW_DIR" "$SOURCE" >/dev/null
RENDERED="$PREVIEW_DIR/LectureGoAppIcon.svg.png"
magick "$RENDERED" \
    \( -size 1024x1024 xc:none -fill white -draw "roundrectangle 32,32 992,992 214,214" \) \
    -alpha off -compose CopyOpacity -composite "$MASTER"

render_size() {
    local pixels="$1"
    local name="$2"
    magick "$MASTER" -resize "${pixels}x${pixels}" "$ICONSET/$name"
}

render_size 16 icon_16x16.png
render_size 32 icon_16x16@2x.png
render_size 32 icon_32x32.png
render_size 64 icon_32x32@2x.png
render_size 128 icon_128x128.png
render_size 256 icon_128x128@2x.png
render_size 256 icon_256x256.png
render_size 512 icon_256x256@2x.png
render_size 512 icon_512x512.png
render_size 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "已生成 $OUTPUT"
