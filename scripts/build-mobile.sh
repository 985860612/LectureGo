#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/mobile"
./gradlew :app:assembleDebug :app:testDebugUnitTest --no-daemon
echo "✅ 移动端构建完成: $ROOT/mobile/app/build/outputs/apk/debug/app-debug.apk"
