#!/bin/zsh
# scripts/sign-appcast.sh — build/release/appcast.xml with Sparkle's
# generate_appcast, signing the DMG with the EdDSA key at
# SPARKLE_PRIVATE_KEY_FILE (keys/ is gitignored; the key is never in the repo).
# Skips with a warning when the variable is unset. The download prefix is the
# Release UpdateFeedURL's directory from AppConfig.plist, so the feed and the
# app agree on the host.
source "$(dirname "$0")/release-env.sh"
[[ -f $DMG ]] || { print -u2 "run make-dmg.sh first ($DMG missing)"; exit 1 }

if [[ -z ${SPARKLE_PRIVATE_KEY_FILE:-} ]]; then
  warn "SPARKLE_PRIVATE_KEY_FILE is not set: skipping appcast signing. Generate keys in 8B with Sparkle's generate_keys and put the public key in project.yml (SUPublicEDKey)."
  exit 0
fi
[[ -f $SPARKLE_PRIVATE_KEY_FILE ]] || { print -u2 "no key at $SPARKLE_PRIVATE_KEY_FILE"; exit 1 }

GENERATE=$(ls "$REPO"/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null | head -1)
[[ -x $GENERATE ]] || { print -u2 "generate_appcast not found; run make build once so SPM fetches Sparkle"; exit 1 }

FEED_DIR=$OUT/feed
rm -rf "$FEED_DIR"; mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
PREFIX=${FEED_URL%/*}/
say "generate_appcast → $FEED_DIR/appcast.xml"
"$GENERATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --download-url-prefix "$PREFIX" \
  -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
print -- "appcast: $FEED_DIR/appcast.xml (upload with $(basename "$DMG") to $PREFIX)"
