#!/bin/zsh
# Builds ChargePilot.app (and ChargePilot.zip, the release archive) into ./build.noindex (".noindex" keeps Spotlight from
# listing build copies). Set CODESIGN_IDENTITY to sign with your Developer ID; otherwise everything is signed ad hoc with
# requirements pinned to each identifier, which is what the helper checks before accepting a connection.
#
# The bundle is assembled and signed outside the project: on a Desktop synced by iCloud, File Provider can add Finder
# attributes at any moment, which makes codesign refuse the bundle and leaves the app with the wrong identity.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
BUILD="$ROOT/build.noindex"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chargepilot-build.XXXXXX")"
APP="$STAGE/ChargePilot.app"
trap 'rm -rf "$STAGE"' EXIT
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

# GitHub "owner/repo" the app checks for updates: UPDATE_REPOSITORY, else the git remote.
if [[ -z "${UPDATE_REPOSITORY:-}" ]]; then
  REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  UPDATE_REPOSITORY="$(sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<< "$REMOTE")"
  [[ "$UPDATE_REPOSITORY" == */* && "$REMOTE" == *github.com* ]] || UPDATE_REPOSITORY=""
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchServices"
cp "$BIN/ChargePilot" "$APP/Contents/MacOS/ChargePilot"
cp "$BIN/ChargePilotCLI" "$APP/Contents/Helpers/chargepilot"
cp "$BIN/ChargePilotHelper" "$APP/Contents/Library/LaunchServices/app.chargepilot.helper"
cp "$ROOT/Scripts/app.chargepilot.helper.plist" "$APP/Contents/Resources/app.chargepilot.helper.plist"

# Icon
ICON_WORK="$STAGE/icon"
rm -rf "$ICON_WORK" && mkdir -p "$ICON_WORK/ChargePilot.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICON_WORK/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_WORK/icon.png" --out "$ICON_WORK/ChargePilot.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON_WORK/icon.png" --out "$ICON_WORK/ChargePilot.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/ChargePilot.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ChargePilot</string>
  <key>CFBundleDisplayName</key><string>ChargePilot</string>
  <key>CFBundleIdentifier</key><string>app.chargepilot.ChargePilot</string>
  <key>CFBundleExecutable</key><string>ChargePilot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>ChargePilotUpdateRepository</key><string>$UPDATE_REPOSITORY</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>app.chargepilot.ChargePilot</string>
      <key>CFBundleURLSchemes</key><array><string>chargepilot</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

xattr -cr "$APP"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" -i app.chargepilot.helper "$APP/Contents/Library/LaunchServices/app.chargepilot.helper"
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" -i app.chargepilot.cli "$APP/Contents/Helpers/chargepilot"
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - -i app.chargepilot.helper \
    --requirements '=designated => identifier "app.chargepilot.helper"' "$APP/Contents/Library/LaunchServices/app.chargepilot.helper"
  codesign --force --sign - -i app.chargepilot.cli \
    --requirements '=designated => identifier "app.chargepilot.cli"' "$APP/Contents/Helpers/chargepilot"
  codesign --force --sign - --requirements '=designated => identifier "app.chargepilot.ChargePilot"' "$APP"
fi
# Refuse to hand over a bundle whose identity the helper would reject.
codesign --verify --deep --strict -R='identifier "app.chargepilot.ChargePilot"' "$APP"
codesign --verify --strict -R='identifier "app.chargepilot.cli"' "$APP/Contents/Helpers/chargepilot"
codesign --verify --strict -R='identifier "app.chargepilot.helper"' "$APP/Contents/Library/LaunchServices/app.chargepilot.helper"

mkdir -p "$BUILD"
rm -rf "$BUILD/ChargePilot.app" "$BUILD/ChargePilot.zip"
ditto -c -k --keepParent "$APP" "$BUILD/ChargePilot.zip"
ditto "$APP" "$BUILD/ChargePilot.app"
echo "Built $BUILD/ChargePilot.app (version $VERSION${UPDATE_REPOSITORY:+, updates from $UPDATE_REPOSITORY})"
