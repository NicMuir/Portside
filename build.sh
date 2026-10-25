#!/bin/sh
# ./build.sh           build Portside.app here and (re)launch it
# ./build.sh install   also copy it to /Applications (where Launch at login expects it) and launch that copy
set -e
cd "$(dirname "$0")"
VERSION=1.0.0
APP=Portside.app

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

# universal binary, both slices compiled in parallel
swiftc -O -swift-version 6 -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o build/Portside-arm64 & a=$!
swiftc -O -swift-version 6 -parse-as-library -target x86_64-apple-macos14.0 Sources/*.swift -o build/Portside-x86_64 & b=$!
wait $a; wait $b
lipo -create build/Portside-arm64 build/Portside-x86_64 -output "$APP/Contents/MacOS/Portside"

"$APP/Contents/MacOS/Portside" --iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Portside</string>
  <key>CFBundleIdentifier</key><string>io.github.nicmuir.portside</string>
  <key>CFBundleName</key><string>Portside</string>
  <key>CFBundleDisplayName</key><string>Portside</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) NicMuir · MIT License</string>
</dict></plist>
EOF
codesign -fs - "$APP" 2>/dev/null

pkill -f "Portside.app/Contents/MacOS/Portside" && while pgrep -f "Portside.app/Contents/MacOS/Portside" >/dev/null; do sleep 0.1; done # so the fresh build is what launches
if [ "$1" = install ]; then
  rm -rf /Applications/Portside.app
  cp -R "$APP" /Applications/
  APP=/Applications/Portside.app
fi
open -n "$APP" # -n: LaunchServices can still think the killed copy is running
echo "Portside $VERSION → $APP"
