#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=".build/release/MacProfiler"
APP="build/Mac Profiler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacProfiler"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
