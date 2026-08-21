#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/courserec-mobile-input.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "color=c=blue:s=64x64:r=30" -frames:v 1 \
  -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency \
  -x264-params "keyint=1:repeat-headers=1" -f h264 "$TMP_DIR/frame.h264"

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "color=c=blue:s=64x64:r=30" -frames:v 1 \
  -pix_fmt yuv420p -c:v libx265 -preset ultrafast -tune zerolatency \
  -x265-params "keyint=1:repeat-headers=1:log-level=error" -f hevc "$TMP_DIR/frame.h265"

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=0.1" \
  -ac 2 -c:a aac -b:a 128k -f adts "$TMP_DIR/audio.aac"

swiftc \
  "$ROOT/Sources/CourseRec/Inputs/PortraitSource.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileWire.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobilePacketHeader.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileFrame.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileReassembler.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileControlClient.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileMediaReceiver.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileTimeline.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileAudioSampleBuilder.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileVideoDecoder.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileInputClient.swift" \
  "$ROOT/Sources/CourseRec/Recording/TrackWriter.swift" \
  "$ROOT/scripts/mobile-input-smoke.swift" \
  -o "$TMP_DIR/mobile-input-smoke"

"$TMP_DIR/mobile-input-smoke" h264 "$TMP_DIR/frame.h264" "$TMP_DIR/audio.aac"
"$TMP_DIR/mobile-input-smoke" h265 "$TMP_DIR/frame.h265" "$TMP_DIR/audio.aac"
