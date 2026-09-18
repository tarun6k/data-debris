#!/bin/zsh
# scripts/build-release.sh — xcodegen, Release archive (universal), export.
#
# With DEVELOPER_ID_APP and DEVELOPMENT_TEAM set: signs with that identity
# and exports through ExportOptions.plist (method developer-id).
# Without them: keeps the project's ad-hoc signature ("Sign to Run Locally")
# and copies the app straight out of the archive, with a loud warning.
# Result: build/release/DataDebris.app
source "$(dirname "$0")/release-env.sh"

say "Data Debris $VERSION ($BUILD)"
if git -C "$REPO" rev-parse -q --verify "refs/tags/v$VERSION-$BUILD" >/dev/null; then
  warn "Tag v$VERSION-$BUILD already exists: bump CURRENT_PROJECT_VERSION in project.yml before releasing again (Sparkle compares CFBundleVersion)."
fi
if [[ -n $(git -C "$REPO" status --porcelain) ]]; then
  warn "Working tree has uncommitted changes; the archive will not match a commit."
fi

say "xcodegen"
(cd "$REPO" && xcodegen generate >/dev/null)

rm -rf "$ARCHIVE" "$APP" "$OUT/export"
SIGNING=()
if [[ -n ${DEVELOPER_ID_APP:-} ]]; then
  : "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required alongside DEVELOPER_ID_APP}"
  SIGNING=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual)
  say "signing with: $DEVELOPER_ID_APP"
else
  warn "DEVELOPER_ID_APP is not set: building with the AD-HOC signature. Gatekeeper will block this app on other Macs; it is fine for local installs only."
fi

say "archive (Release, arm64 + x86_64)"
xcodebuild -project "$REPO/DataDebris.xcodeproj" -scheme "$PRODUCT" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$REPO/build" \
  -archivePath "$ARCHIVE" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO "${SIGNING[@]}" \
  archive | grep -E "error:|warning: .*(sign|entitle)|\*\* ARCHIVE" || true
[[ -d "$ARCHIVE/Products/Applications/$PRODUCT.app" ]] || { print -u2 "archive failed"; exit 1 }

if [[ -n ${DEVELOPER_ID_APP:-} ]]; then
  say "export (developer-id)"
  cp "$REPO/scripts/ExportOptions.plist" "$OUT/ExportOptions.plist"
  plutil -replace signingCertificate -string "$DEVELOPER_ID_APP" "$OUT/ExportOptions.plist"
  plutil -replace teamID -string "$DEVELOPMENT_TEAM" "$OUT/ExportOptions.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" | grep -E "error:|EXPORT" || true
  mv "$OUT/export/$PRODUCT.app" "$APP"
else
  cp -R "$ARCHIVE/Products/Applications/$PRODUCT.app" "$APP"
fi

say "verify"
lipo -archs "$APP/Contents/MacOS/$PRODUCT"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -2
codesign -dv "$APP" 2>&1 | grep -E "^(Authority|Signature|TeamIdentifier)" || true
plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" | sed 's/^/CFBundleVersion: /'
print -- "app: $APP"
