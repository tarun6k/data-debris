PROJECT := DataDebris.xcodeproj
SCHEME := DataDebris
DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/DataDebris.app

.PHONY: gen build test run clean dist release icon

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) build

test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) $(PROJECT)

# Beta distribution without a Developer ID: universal Release archive,
# ad-hoc signature with Hardened Runtime applied inside out, DMG and its
# .sha256. Output: build/release/ (DMG_SUFFIX, e.g. -beta.1, is appended to
# the DMG name by the release workflow).
dist:
	scripts/build-release.sh
	scripts/make-dmg.sh

# Full chain: dist + notarization and signed appcast when the identities are
# exported (see scripts/release-env.sh). Output: build/release/
release:
	scripts/release.sh

icon:
	scripts/make-icon.sh
