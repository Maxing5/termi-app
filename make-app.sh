#!/bin/bash
# make-app.sh — build Termi and assemble a real .app bundle in ~/Applications.
#
# There's no Xcode on this machine, so the bundle is put together by hand:
# SwiftPM produces the binary, we write Info.plist, then ad-hoc codesign.
# Bundling matters for more than tidiness — an unbundled binary has no bundle
# identifier, which is what UNUserNotificationCenter needs.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Termi"
BUNDLE_ID="com.termi.app"
DEST="$HOME/Applications/$APP_NAME.app"

echo "==> building release"
swift build -c release

echo "==> assembling bundle"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp ".build/release/$APP_NAME" "$DEST/Contents/MacOS/$APP_NAME"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>              <string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>        <string>$APP_NAME</string>
	<key>CFBundlePackageType</key>       <string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key>           <string>1</string>
	<key>LSMinimumSystemVersion</key>    <string>14.0</string>
	<key>LSUIElement</key>               <true/>
	<key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

plutil -lint "$DEST/Contents/Info.plist" > /dev/null

echo "==> ad-hoc signing"
codesign --force --sign - --timestamp=none "$DEST"

echo "==> registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" 2>/dev/null || true

echo
echo "installed: $DEST"
echo "run it:    open -a \"$DEST\""
