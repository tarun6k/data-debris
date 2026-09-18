#!/bin/zsh
# scripts/notarize.sh [path] — notarize and staple an .app or .dmg.
#
# Uses `xcrun notarytool submit --keychain-profile "$NOTARY_PROFILE" --wait`
# (credentials live in the login keychain, stored once with
# `xcrun notarytool store-credentials`). Skips with a warning when
# NOTARY_PROFILE is unset. Default path: build/release/DataDebris.app.
source "$(dirname "$0")/release-env.sh"
TARGET=${1:-$APP}

if [[ -z ${NOTARY_PROFILE:-} ]]; then
  warn "NOTARY_PROFILE is not set: skipping notarization of $(basename "$TARGET"). Gatekeeper will warn on other Macs."
  exit 0
fi
if ! codesign -dv "$TARGET" 2>&1 | grep -q "Authority=Developer ID"; then
  warn "$(basename "$TARGET") is not Developer ID signed; Apple will reject it. Set DEVELOPER_ID_APP and rebuild."
  exit 1
fi

case $TARGET in
  *.app)
    SUBMIT=$OUT/$(basename "$TARGET" .app)-notarize.zip
    rm -f "$SUBMIT"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
    ;;
  *) SUBMIT=$TARGET ;;
esac

say "notarytool submit $(basename "$SUBMIT")"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$NOTARY_PROFILE" --wait
say "staple"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
[[ $SUBMIT == *-notarize.zip ]] && rm -f "$SUBMIT"
print -- "notarized: $TARGET"
