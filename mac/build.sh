#!/bin/bash
# Builds CleanIT.app into mac/build/. Usage: ./build.sh [--debug] [--zip] [--open]
# Release builds are universal (Intel + Apple silicon). --zip also writes build/CleanIT-Mac.zip for GitHub releases.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG=release; [[ " $* " == *" --debug "* ]] && CONFIG=debug
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/CleanIT/Util.swift)

ARCH=(); [[ $CONFIG == release ]] && ARCH=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCH[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH[@]}" --show-bin-path)/CleanIT"

APP=build/CleanIT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/CleanIT"
cp web/index.html web/app.js web/mac.css "$APP/Contents/Resources/web/"
cp ../web/app.css "$APP/Contents/Resources/web/app.css"     # shared with the Windows UI

# icon: the app draws its own mark; iconutil turns it into an .icns
TMP=$(mktemp -d)
"$APP/Contents/MacOS/CleanIT" --make-icon "$TMP"
iconutil -c icns "$TMP/CleanIT.iconset" -o "$APP/Contents/Resources/CleanIT.icns"
cp "$TMP/favicon.png" "$APP/Contents/Resources/web/favicon.png"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CleanIT</string>
  <key>CFBundleDisplayName</key><string>CleanIT</string>
  <key>CFBundleIdentifier</key><string>io.github.juicethekidd99.cleanit</string>
  <key>CFBundleExecutable</key><string>CleanIT</string>
  <key>CFBundleIconFile</key><string>CleanIT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSAppleEventsUsageDescription</key><string>CleanIT reads and changes your Login Items through System Events.</string>
</dict>
</plist>
PLIST

# ad-hoc signature so macOS can identify the app (Full Disk Access, notifications)
codesign --force --deep --sign - "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/CleanIT"))"
if [[ " $* " == *" --zip "* ]]; then
  rm -f build/CleanIT-Mac.zip
  ditto -c -k --keepParent "$APP" build/CleanIT-Mac.zip     # ditto keeps the signature and permissions intact
  echo "Zipped build/CleanIT-Mac.zip"
fi
[[ " $* " == *" --open "* ]] && open "$APP"
exit 0
