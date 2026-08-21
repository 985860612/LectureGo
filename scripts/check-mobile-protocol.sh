#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp /tmp/courserec-mobile-protocol-check.XXXXXX)"
trap 'rm -f "$OUT"' EXIT

swiftc \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileWire.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobilePacketHeader.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileFrame.swift" \
  "$ROOT/Sources/CourseRec/Inputs/Mobile/MobileReassembler.swift" \
  "$ROOT/scripts/mobile-protocol-check.swift" \
  -o "$OUT"
"$OUT"
