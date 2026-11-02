#!/bin/zsh
# scripts/build-release.sh — xcodegen, Release archive (universal), export.
#
# With DEVELOPER_ID_APP and DEVELOPMENT_TEAM set: signs with that identity
# and exports through ExportOptions.plist (method developer-id).
# Without them: copies the app straight out of the archive and re-signs it
# ad hoc ("Sign to Run Locally") with Hardened Runtime, inside out, with a
# loud warning. Result: build/release/DataDebris.app
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
  warn "DEVELOPER_ID_APP is not set: building with the AD-HOC signature. Gatekeeper will block this app on other Macs until the user chooses Open Anyway."
fi

say "archive (Release, arm64 + x86_64)"
xcodebuild -project "$REPO/DataDebris.xcodeproj" -scheme "$PRODUCT" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$REPO/build" \
  -archivePath "$ARCHIVE" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO "${SIGNING[@]}" \
  archive | grep -E "error:|warning: .*(sign|entitle)|\*\* ARCHIVE" || true
[[ -d "$ARCHIVE/Products/Applications/$PRODUCT.app" ]] || { print -u2 "archive failed"; exit 1 }

# Ad-hoc signing, inside out. A bundle's signature seals the code hashes of
# everything nested in it, so nested code has to be signed before (never
# after) the bundle that contains it, or the outer seal is invalidated:
#   1. each embedded framework (DebrisCore, Sparkle), with Hardened Runtime;
#   2. the app itself, with the library-validation exemption.
# No --deep: it would push the app's entitlements into the frameworks and
# Sparkle's helpers. Sparkle's own XPC services and helpers keep the
# signatures Sparkle shipped them with (valid, and the updater is off in
# this build anyway).
# Why the exemption: an ad-hoc signature carries no Team ID, and Hardened
# Runtime library validation only admits libraries signed by Apple or by the
# process's own team, so an ad-hoc app refuses its own ad-hoc frameworks
# ("mapped file ... have different Team IDs"). Developer ID gives the app and
# the frameworks one team, so the export path above never needs it.
adhoc_sign() {
  local app=$1
  cat > "$OUT/adhoc.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
  local framework
  for framework in "$app"/Contents/Frameworks/*.framework(N); do
    say "codesign (ad hoc, runtime): $(basename "$framework")"
    codesign --force --sign - --options runtime --timestamp=none \
      --preserve-metadata=identifier,entitlements "$framework"
  done
  say "codesign (ad hoc, runtime, library validation off): $(basename "$app")"
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$OUT/adhoc.entitlements" "$app"
}

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
  adhoc_sign "$APP"
fi

say "verify"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")
lipo -info "$APP/Contents/MacOS/$PRODUCT"
[[ $ARCHS == *arm64* && $ARCHS == *x86_64* ]] || { print -u2 "not a universal binary: $ARCHS"; exit 1 }
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
# Captured first: with pipefail, `codesign | grep -q` fails on a match (grep
# exits early, codesign gets SIGPIPE). Ad hoc shows flags=0x10002(adhoc,runtime),
# Developer ID flags=0x10000(runtime); both carry the Hardened Runtime bit.
SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
print -- "$SIGN_INFO" | grep -E "^(Identifier|Authority|Signature|TeamIdentifier|CodeDirectory)" || true
FLAGS=$(print -- "$SIGN_INFO" | sed -n 's/.*flags=\(0x[0-9a-f]*([^)]*)\).*/\1/p' | head -1)
[[ $FLAGS == *runtime* ]] || { print -u2 "Hardened Runtime flag missing on $APP (flags=$FLAGS)"; exit 1 }
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E 'disable-library-validation' | sed 's/^/entitlement: /' || true
plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" | sed 's/^/CFBundleShortVersionString: /'
plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" | sed 's/^/CFBundleVersion: /'
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || warn "AppIcon.icns missing from the bundle (asset catalog not compiled?)"
print -- "app: $APP"
