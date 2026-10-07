#!/bin/bash
# Builds Weight Tracker with swiftc (no Xcode project needed) and packages the .app.
#
#   ./build.sh             → build/Weight Tracker.app
#   ./build.sh --install   → also copies it to /Applications
#
# Needs Xcode (or the Command Line Tools) on an Apple silicon or Intel Mac, macOS 14+.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Weight Tracker"
EXE="WeightTracker"
ARCH="$(uname -m)"
MIN="14.0"
OUT="build"
APP="$OUT/$APP_NAME.app"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

# Prefer the full Xcode toolchain (needed for the SwiftUI macros). This only applies to
# this build; the system setting (xcode-select) isn't changed.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$x/Contents/Developer" ]; then export DEVELOPER_DIR="$x/Contents/Developer"; break; fi
  done
fi

echo "== Toolchain =="
if ! xcrun swiftc --version; then
  echo "swiftc couldn't run. If the Xcode license hasn't been accepted yet, run:"
  echo "  sudo xcodebuild -license accept"
  exit 1
fi

echo "== Compile =="
mkdir -p "$OUT"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$ARCH-apple-macos$MIN" \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  Sources/*.swift -o "$OUT/$EXE"

echo "== Package =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
cp -f Info.plist "$APP/Contents/Info.plist"
cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lang in en tr; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cp -f Resources/$lang.lproj/*.strings "$APP/Contents/Resources/$lang.lproj/"
done
codesign --force --sign - "$APP"          # ad-hoc signature (not notarized)
codesign --verify "$APP"

echo "== PDF test (generated sample data) =="
PDF="$PWD/$OUT/sample_report.pdf"
"$APP/Contents/MacOS/$EXE" --sample-pdf "$PDF" &
PID=$!
for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
kill "$PID" 2>/dev/null || true
if [ -s "$PDF" ]; then echo "PDF test OK: $(wc -c < "$PDF" | tr -d ' ') bytes"; else echo "WARNING: PDF test produced no file"; fi

if [ "$INSTALL" = 1 ]; then
  echo "== Install =="
  ditto "$APP" "/Applications/$APP_NAME.app"
  codesign --force --sign - "/Applications/$APP_NAME.app"
  echo "Installed: /Applications/$APP_NAME.app"
fi
echo "Done: $APP"
