#!/bin/sh
# Build a release binary and assemble Buildwright.app in dist/.
# Usage: Scripts/bundle.sh [--install]   (--install copies to /Applications)
set -e

cd "$(dirname "$0")/.."

if [ -d "/Applications/Xcode.app" ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

VERSION="0.22.0"
BUILD_NUMBER="23"

echo "Building release binary..."
swift build -c release

APP="dist/Buildwright.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -X: drop extended attributes — macOS provenance xattrs survive xattr -cr
# and make codesign reject the bundle ("detritus not allowed").
cp -X ".build/release/Buildwright" "$APP/Contents/MacOS/Buildwright"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Buildwright</string>
    <key>CFBundleIdentifier</key>
    <string>com.rvance.buildwright</string>
    <key>CFBundleName</key>
    <string>Buildwright</string>
    <key>CFBundleDisplayName</key>
    <string>Buildwright</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Buildwright tiles the CVR Chromium window beside the IDE.</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Strip extended attributes (FinderInfo/quarantine) — codesign rejects them.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

echo "Built $APP"

# Rollback insurance: keep every version. A bad build never blocks work —
#   rm -rf /Applications/Buildwright.app && cp -R dist/archive/Buildwright-<ver>.app /Applications/Buildwright.app
mkdir -p dist/archive
rm -rf "dist/archive/Buildwright-$VERSION.app"
cp -R "$APP" "dist/archive/Buildwright-$VERSION.app"
echo "Archived dist/archive/Buildwright-$VERSION.app"

if [ "$1" = "--install" ]; then
  rm -rf "/Applications/Buildwright.app"
  cp -R "$APP" "/Applications/Buildwright.app"
  echo "Installed to /Applications/Buildwright.app"
fi
