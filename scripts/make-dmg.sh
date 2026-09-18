#!/bin/zsh
# scripts/make-dmg.sh — build/release/DataDebris-<version>.dmg with hdiutil.
#
# Layout: the app on the left, an "Applications" link on the right, the app
# icon as the volume icon. Finder positions the two icons (best effort; the
# DMG is still valid if Finder scripting is unavailable). The volume icon is
# added after the Finder pass: Finder removes .VolumeIcon.icns and clears the
# custom-icon flag when it rewrites the folder. Signs the DMG when
# DEVELOPER_ID_APP is set; notarize.sh can then staple it.
source "$(dirname "$0")/release-env.sh"
[[ -d $APP ]] || { print -u2 "run build-release.sh first ($APP missing)"; exit 1 }

STAGING=$OUT/dmg-root
RW=$OUT/$PRODUCT-rw.dmg
rm -rf "$STAGING" "$RW" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

say "hdiutil create (read-write)"
hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ \
  -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
[[ -n $MOUNT ]] || { print -u2 "mount failed"; exit 1 }

say "Finder layout"
osascript - "$MOUNT" "$PRODUCT" <<'APPLESCRIPT' || warn "Finder layout skipped (osascript failed); the DMG still works."
on run argv
  set mountPath to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk (name of (POSIX file mountPath as alias))
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 760, 460}
      set theOptions to the icon view options of container window
      set arrangement of theOptions to not arranged
      set icon size of theOptions to 112
      set position of item (appName & ".app") of container window to {150, 160}
      set position of item "Applications" of container window to {410, 160}
      close
      open
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT

say "volume icon"
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SETFILE=$(xcrun --find SetFile 2>/dev/null || true)
if [[ -n $SETFILE ]]; then "$SETFILE" -a C "$MOUNT"; else warn "SetFile not found; the volume icon flag was not set."; fi
sync
hdiutil detach -quiet "$MOUNT"

say "hdiutil convert (compressed, read-only)"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$RW" "$STAGING"

if [[ -n ${DEVELOPER_ID_APP:-} ]]; then
  say "codesign dmg"
  codesign --sign "$DEVELOPER_ID_APP" --timestamp "$DMG"
else
  warn "DEVELOPER_ID_APP is not set: the DMG is unsigned."
fi
print -- "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
