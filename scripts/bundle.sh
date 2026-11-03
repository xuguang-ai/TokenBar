#!/usr/bin/env bash
# Build the TokenBarApp SwiftPM product and wrap it into an ad-hoc signed, menu-bar-only TokenBar.app.
#
#   scripts/bundle.sh                 # release build -> dist/TokenBar.app
#   CONFIG=debug scripts/bundle.sh    # debug build
#   scripts/bundle.sh <extra swift build args>
#
# Env overrides: CONFIG, OUT_DIR, APP_NAME, BUNDLE_ID, VERSION, BUILD_NUMBER, MIN_MACOS
set -euo pipefail

# Toolchain: $DEVELOPER_DIR if set, else the active developer directory (xcode-select). When that one cannot
# run swift (for example an Xcode whose license has not been accepted), fall back to the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! swift --version >/dev/null 2>&1 \
  && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
PRODUCT="TokenBarApp"
APP_NAME="${APP_NAME:-TokenBar}"
BUNDLE_ID="${BUNDLE_ID:-dev.tokenbar.TokenBar}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_MACOS="${MIN_MACOS:-14.0}"  # keep in sync with Package.swift platforms
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
APP="$OUT_DIR/$APP_NAME.app"

swift build --package-path "$ROOT" -c "$CONFIG" --product "$PRODUCT" "$@"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path "$@")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundles (none today). Verified with SwiftPM 6.2.4: the generated Bundle.module accessor
# only looks at Bundle.main.bundleURL/<Pkg>_<Target>.bundle (= the .app root, which codesign rejects) and at
# the absolute .build path (works until .build is deleted). So inside the .app use Bundle.main and files in
# Contents/Resources (put app assets in ./Resources and copy them here) instead of SwiftPM resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  echo "warning: $(basename "$bundle"): Bundle.module will NOT find it inside the .app (see comment)" >&2
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

ICON_KEY=""
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  ${ICON_KEY}
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "Built $APP"
