#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/courserec-davinci-check.XXXXXX")"

cleanup() {
  if [[ -n "$CHECK_DIR" && "$CHECK_DIR" == *courserec-davinci-check.* ]]; then
    rm -r "$CHECK_DIR"
  fi
}
trap cleanup EXIT

xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/CourseRec/Recording/DavinciTimelineExporter.swift" \
  "$ROOT/scripts/davinci-timeline-check.swift" \
  -o "$CHECK_DIR/davinci-timeline-check"

"$CHECK_DIR/davinci-timeline-check"

if command -v ffmpeg >/dev/null 2>&1; then
  MEDIA_DIR="$CHECK_DIR/课录-媒体探测"
  mkdir "$MEDIA_DIR"
  ffmpeg -loglevel error -y -f lavfi -i color=c=black:s=320x180:r=30 -t 0.2 \
    -c:v libx264 -pix_fmt yuv420p "$MEDIA_DIR/屏幕ISO.mov"
  cp "$MEDIA_DIR/屏幕ISO.mov" "$MEDIA_DIR/人像ISO.mov"
  cp "$MEDIA_DIR/屏幕ISO.mov" "$MEDIA_DIR/成片.mov"
  ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.2 \
    -c:a aac "$MEDIA_DIR/人声.m4a"
  cp "$MEDIA_DIR/人声.m4a" "$MEDIA_DIR/系统声.m4a"
  cp "$MEDIA_DIR/人声.m4a" "$MEDIA_DIR/成片混音.m4a"
  "$CHECK_DIR/davinci-timeline-check" "$MEDIA_DIR"
  xmllint --noout "$MEDIA_DIR/课录.xml"
fi
