#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/DockSwipe.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/.build/debug/DockSwipe" "$MACOS_DIR/DockSwipe"

/usr/libexec/PlistBuddy -c "Clear dict" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string DockSwipe" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string DockSwipe" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.codex.DockSwipe" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string DockSwipe" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
