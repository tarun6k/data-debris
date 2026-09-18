PROJECT := DataDebris.xcodeproj
SCHEME := DataDebris
DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/DataDebris.app

.PHONY: gen build test run clean release icon

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

# Release archive + DMG (+ notarization and signed appcast when the
# identities are exported; see scripts/release-env.sh). Output: build/release/
release:
	scripts/release.sh

icon:
	scripts/make-icon.sh
