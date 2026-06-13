#!/bin/sh
# Build a release binary and assemble Buildwright.app in dist/.
# Usage: Scripts/bundle.sh [--install]   (--install copies to /Applications)
set -e

cd "$(dirname "$0")/.."

if [ -d "/Applications/Xcode.app" ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

VERSION="0.31.0"
BUILD_NUMBER="34"

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

# Stable signing so macOS privacy (TCC) grants — Automation, Accessibility,
# Notifications — PERSIST across rebuilds. Ad-hoc (--sign -) changes the
# signature every build, so macOS treats each install as a new app and resets
# every grant, re-prompting forever. Run Scripts/make-signing-cert.sh once to
# create the identity; until then we fall back to ad-hoc with a warning.
# Match by HASH, not name: a self-signed identity is untrusted (so it's
# absent from `find-identity -v`) and signing by name is ambiguous if more
# than one exists — both make codesign silently fall back to ad-hoc.
SIGN_IDENTITY="${BW_SIGN_IDENTITY:-Buildwright Self-Signed}"
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" | head -1 | awk '{print $2}')"
if [ -n "$SIGN_HASH" ]; then
  codesign --force --deep --sign "$SIGN_HASH" "$APP"
  echo "Signed with stable identity $SIGN_IDENTITY ($SIGN_HASH) -- TCC grants persist across updates."
else
  codesign --force --deep --sign - "$APP"
  echo "WARNING: ad-hoc signed. Privacy permissions will reset every update."
  echo "         Run Scripts/make-signing-cert.sh once, then rebuild, to make them stick."
fi

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
