#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-OpenPet}"
PRODUCT_NAME="${PRODUCT_NAME:-CompanionPet}"
BUNDLE_ID="${BUNDLE_ID:-io.openpet.OpenPet}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SKIP_BUILD="${SKIP_BUILD:-0}"

ARTIFACT_DIR="$ROOT_DIR/.build/$CONFIGURATION"
EXECUTABLE_PATH="$ARTIFACT_DIR/$PRODUCT_NAME"
RESOURCE_BUNDLE_PATH="$ARTIFACT_DIR/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
INFO_PLIST_PATH="$CONTENTS_PATH/Info.plist"
PLIST_TEMPLATE="$ROOT_DIR/packaging/Info.plist"
MODULE_BUNDLE_NAME="$(basename "$RESOURCE_BUNDLE_PATH")"
MODULE_BUNDLE_PATH="$RESOURCES_PATH/$MODULE_BUNDLE_NAME"
MODULE_BUNDLE_CONTENTS_PATH="$MODULE_BUNDLE_PATH/Contents"
MODULE_BUNDLE_RESOURCES_PATH="$MODULE_BUNDLE_CONTENTS_PATH/Resources"
MODULE_BUNDLE_PLIST_PATH="$MODULE_BUNDLE_CONTENTS_PATH/Info.plist"

if [[ "$SKIP_BUILD" != "1" ]]; then
  swift build -c "$CONFIGURATION"
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  printf 'Missing executable at %s\n' "$EXECUTABLE_PATH" >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
  printf 'Missing SwiftPM resource bundle at %s\n' "$RESOURCE_BUNDLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH" "$MODULE_BUNDLE_RESOURCES_PATH"

cp "$EXECUTABLE_PATH" "$MACOS_PATH/$PRODUCT_NAME"
cp "$PLIST_TEMPLATE" "$INFO_PLIST_PATH"
ditto "$RESOURCE_BUNDLE_PATH" "$MODULE_BUNDLE_RESOURCES_PATH"

cat > "$MODULE_BUNDLE_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}.resources</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${MODULE_BUNDLE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
</dict>
</plist>
EOF

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST_PATH"

codesign --force --sign "$SIGN_IDENTITY" "$MACOS_PATH/$PRODUCT_NAME"
codesign --force --sign "$SIGN_IDENTITY" "$MODULE_BUNDLE_PATH"
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"

printf 'Packaged %s\n' "$APP_PATH"
