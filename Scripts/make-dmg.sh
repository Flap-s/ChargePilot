#!/bin/zsh
# Packs ChargePilot.app into an installer disk image whose window invites dragging the app onto Applications.
# Usage: Scripts/make-dmg.sh <ChargePilot.app> <output.dmg>
# Lays the window out through Finder, so the first run asks to let the terminal control Finder.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP="${1:?usage: Scripts/make-dmg.sh <ChargePilot.app> <output.dmg>}"
OUTPUT="${2:?usage: Scripts/make-dmg.sh <ChargePilot.app> <output.dmg>}"
VOLUME="ChargePilot"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chargepilot-dmg.XXXXXX")"
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Contents: the app, a link to Applications, and the background (1× and 2× in one TIFF for Retina screens).
mkdir -p "$WORK/content/.background"
ditto "$APP" "$WORK/content/ChargePilot.app"
ln -s /Applications "$WORK/content/Applications"
swift "$ROOT/Scripts/make-dmg-background.swift" "$WORK/background.png" 1
swift "$ROOT/Scripts/make-dmg-background.swift" "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/content/.background/background.tiff" >/dev/null

# A volume with this name already mounted would catch Finder's layout instead.
for volume in /Volumes/$VOLUME*(N); do hdiutil detach "$volume" -quiet -force || true; done

hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/content" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF }')"

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 548}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 112
    set text size of options to 13
    set background picture of options to file ".background:background.tiff"
    set position of item "ChargePilot.app" of container window to {170, 200}
    set position of item "Applications" of container window to {470, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Make sure Finder has written its layout (.DS_Store) before sealing the image.
for _ in {1..20}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
# The volume icon is the app icon. Added after Finder's pass, which drops it otherwise.
cp "$WORK/content/ChargePilot.app/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a V "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
SetFile -a E "$MOUNT/ChargePilot.app"   # "ChargePilot" rather than "ChargePilot.app", unless the user shows all extensions
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

rm -f "$OUTPUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$OUTPUT"
echo "Built $OUTPUT"
