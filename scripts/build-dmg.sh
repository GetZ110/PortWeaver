#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
./scripts/build-app.sh
STAGING="$(mktemp -d "$TASK_ROOT/build/dmg-stage.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT
ARCH_TAG="$(uname -m)"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then ARCH_TAG=universal; fi
DMG_PATH="$TASK_ROOT/build/PortWeaver-1.0.0-$ARCH_TAG.dmg"
ditto build/PortWeaver.app "$STAGING/PortWeaver.app"
ln -s /Applications "$STAGING/Applications"
cp INSTALL.txt "$STAGING/安装说明.txt"
hdiutil create -volname PortWeaver -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
printf 'DMG: %s\n' "$DMG_PATH"
