#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
CONFIGURATION="${CONFIGURATION:-release}"
ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then ARCH_ARGS=(--arch arm64 --arch x86_64); fi
xcrun swift build -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(xcrun swift build -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"
APP_PATH="$TASK_ROOT/build/PortWeaver.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/PortWeaver" "$APP_PATH/Contents/MacOS/PortWeaver"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier app.portweaver.mac" "$APP_PATH/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/"; fi
chmod +x "$APP_PATH/Contents/MacOS/PortWeaver"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_PATH"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
