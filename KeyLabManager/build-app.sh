#!/bin/zsh
# Builds "KeyLab Manager.app" (release) and the klctl command-line tool.
# Usage: ./build-app.sh [install]   — "install" copies the app to ~/Applications
set -euo pipefail
cd "${0:A:h}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD="$HOME/Library/Caches/KeyLabManager-build"
swift build -c release --scratch-path "$BUILD"
BIN="$BUILD/release"

APP="dist/KeyLab Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KeyLabManager" "$APP/Contents/MacOS/KeyLabManager"
cp Sources/KeyLabCore/Resources/kl2-schema.json "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] || swift tools/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/klctl" dist/klctl

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KeyLab Manager</string>
  <key>CFBundleDisplayName</key><string>KeyLab Manager</string>
  <key>CFBundleIdentifier</key><string>local.keylab-manager</string>
  <key>CFBundleExecutable</key><string>KeyLabManager</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/KeyLab Manager.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed: $HOME/Applications/KeyLab Manager.app"
fi
