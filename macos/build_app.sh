#!/bin/bash
# Сборка RedCast.app. Нужен Mac с Apple Silicon, macOS 14+ и Xcode 16+ (или Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Сборка (первый раз скачиваются зависимости, 1–3 минуты)…"
swift build -c release --arch arm64

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/RedCast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RedCast" "$APP/Contents/MacOS/RedCast"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (если есть)
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

echo "▸ Подпись (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Готово: $(pwd)/$APP"
echo "  Установить:  cp -R \"$APP\" /Applications/  &&  open \"/Applications/RedCast.app\""
