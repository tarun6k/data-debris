#!/bin/zsh
# scripts/release.sh — the whole release in order:
#   build-release.sh → notarize.sh (app) → make-dmg.sh → notarize.sh (dmg) → sign-appcast.sh
# Each step reads its identity from the environment and warns loudly when it
# is missing (see release-env.sh), so an unsigned local build still completes.
source "$(dirname "$0")/release-env.sh"
S=$REPO/scripts
"$S/build-release.sh"
"$S/notarize.sh" "$APP"
"$S/make-dmg.sh"
"$S/notarize.sh" "$DMG"
"$S/sign-appcast.sh"

print -- "\n=== Artefacts ==="
print -- "app:     $APP"
print -- "dmg:     $DMG"
[[ -f $OUT/feed/appcast.xml ]] && print -- "appcast: $OUT/feed/appcast.xml" || print -- "appcast: not signed (SPARKLE_PRIVATE_KEY_FILE unset)"
if [[ -z ${DEVELOPER_ID_APP:-} || -z ${NOTARY_PROFILE:-} || -z ${SPARKLE_PRIVATE_KEY_FILE:-} ]]; then
  print -- "\nNOT SHIPPABLE: set DEVELOPER_ID_APP, DEVELOPMENT_TEAM, NOTARY_PROFILE and SPARKLE_PRIVATE_KEY_FILE (Phase 8B)."
fi
