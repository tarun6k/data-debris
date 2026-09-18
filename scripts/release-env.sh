#!/bin/zsh
# scripts/release-env.sh — shared by the release scripts (sourced, not run).
#
# Identities and secrets come only from the environment so 8B just exports
# them; nothing here is read from the repo:
#   DEVELOPER_ID_APP          "Developer ID Application: Name (TEAMID)"
#   DEVELOPMENT_TEAM          the 10-character team id (needed with DEVELOPER_ID_APP)
#   NOTARY_PROFILE            `xcrun notarytool store-credentials` profile name
#   SPARKLE_PRIVATE_KEY_FILE  path to the EdDSA private key (keys/ is gitignored)
set -euo pipefail
cd "$(dirname "${(%):-%x}")/.."
REPO=$PWD
OUT=$REPO/build/release
PRODUCT=DataDebris
VOLUME_NAME="Data Debris"
ARCHIVE=$OUT/$PRODUCT.xcarchive
APP=$OUT/$PRODUCT.app
mkdir -p "$OUT"

warn() { print -u2 -- "\n!!! $*\n" }
say()  { print -- "--- $*" }

# Version and build from project.yml (the generated project mirrors them).
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$REPO/project.yml" | head -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\).*/\1/p' "$REPO/project.yml" | head -1)
DMG=$OUT/$PRODUCT-$VERSION.dmg

# Release AppConfig values the scripts must agree with.
FEED_URL=$(plutil -extract Release.UpdateFeedURL raw -o - "$REPO/Sources/DebrisApp/Resources/AppConfig.plist")
