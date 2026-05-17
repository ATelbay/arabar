#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT="$SCRIPT_DIR/.."
cd "$ROOT"

APP_PATH="build/arabar.app"
CONTENTS="$APP_PATH/Contents"

echo "==> Building arabar ($CONFIG)..."
swift build -c "$CONFIG"

echo "==> Assembling .app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy binary
cp ".build/$CONFIG/arabar" "$CONTENTS/MacOS/arabar"
chmod +x "$CONTENTS/MacOS/arabar"

# Copy Info.plist
cp "arabar/Info.plist" "$CONTENTS/Info.plist"

# Ensure required keys are present in Info.plist
PLIST="$CONTENTS/Info.plist"
BUDDY=/usr/libexec/PlistBuddy

add_key_if_missing() {
    local key="$1" type="$2" value="$3"
    if ! "$BUDDY" -c "Print :$key" "$PLIST" &>/dev/null; then
        "$BUDDY" -c "Add :$key $type $value" "$PLIST"
        echo "  Added missing key: $key"
    fi
}

add_key_if_missing "CFBundleExecutable"    "string" "arabar"
add_key_if_missing "CFBundleIdentifier"    "string" "com.arystantelbay.arabar"
add_key_if_missing "CFBundleName"          "string" "arabar"
add_key_if_missing "CFBundleIconName"      "string" "AppIcon"
add_key_if_missing "CFBundleIconFile"      "string" "AppIcon"
add_key_if_missing "LSMinimumSystemVersion" "string" "14.0"
add_key_if_missing "LSUIElement"           "bool"   "true"

# Copy SPM resource bundle if it exists (try both known naming patterns)
BUNDLE_COPIED=0
COPIED_BUNDLE_NAME=""
for BUNDLE_NAME in "arabar_arabar.bundle" "arabar_arabar.resources"; do
    BUNDLE_SRC=".build/$CONFIG/$BUNDLE_NAME"
    if [ -d "$BUNDLE_SRC" ]; then
        cp -R "$BUNDLE_SRC" "$CONTENTS/Resources/"
        echo "  Copied resource bundle: $BUNDLE_NAME"
        BUNDLE_COPIED=1
        COPIED_BUNDLE_NAME="$BUNDLE_NAME"
        break
    fi
done
if [ "$BUNDLE_COPIED" -eq 0 ]; then
    echo "  (No SPM resource bundle found — skipping)"
fi

# Compile Assets.xcassets into Assets.car and place it in the MAIN bundle's
# Resources/ (not the SPM resource bundle). The SPM resource bundle has no
# Info.plist, so NSBundle/AppKit treats it as invalid for Asset Catalog lookup.
# Loading from Bundle.main works reliably, so we use Image("Name") without bundle:.
if [ -d "arabar/Assets.xcassets" ]; then
    echo "==> Compiling asset catalog with actool..."
    ACTOOL_OUT_DIR=$(mktemp -d)
    ACTOOL_PLIST=$(mktemp /tmp/actool_partial_XXXXXX.plist)
    xcrun actool \
        --compile "$ACTOOL_OUT_DIR" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ACTOOL_PLIST" \
        "arabar/Assets.xcassets"
    if [ -f "$ACTOOL_OUT_DIR/Assets.car" ]; then
        cp "$ACTOOL_OUT_DIR/Assets.car" "$CONTENTS/Resources/Assets.car"
        echo "  Placed Assets.car in $CONTENTS/Resources/"
    else
        echo "  WARNING: actool did not produce Assets.car in $ACTOOL_OUT_DIR"
        ls "$ACTOOL_OUT_DIR" || true
    fi
    if [ -f "$ACTOOL_OUT_DIR/AppIcon.icns" ]; then
        cp "$ACTOOL_OUT_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
        echo "  Placed AppIcon.icns in $CONTENTS/Resources/"
    fi
    # Clean up the raw xcassets from the SPM resource bundle (it's not used).
    if [ "$BUNDLE_COPIED" -eq 1 ]; then
        rm -rf "$CONTENTS/Resources/$COPIED_BUNDLE_NAME/Assets.xcassets"
        rm -rf "$CONTENTS/Resources/$COPIED_BUNDLE_NAME/Assets.car"
    fi
    rm -rf "$ACTOOL_OUT_DIR" "$ACTOOL_PLIST"
fi

# Ad-hoc code sign so macOS allows running without Gatekeeper block
echo "==> Code-signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_PATH"

# Final report
BINARY_SIZE=$(du -sh "$CONTENTS/MacOS/arabar" | cut -f1)
APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
ABSOLUTE_PATH=$(cd "$APP_PATH" && pwd)

echo ""
echo "==> Done!"
echo "    Bundle : $ABSOLUTE_PATH"
echo "    Binary : $BINARY_SIZE"
echo "    Total  : $APP_SIZE"
echo ""
echo "    To run: open build/arabar.app"
echo "    To install: cp -R build/arabar.app /Applications/ && open /Applications/arabar.app"
