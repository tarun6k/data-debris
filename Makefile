PROJECT := DataDebris.xcodeproj
SCHEME := DataDebris
DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/DataDebris.app

.PHONY: gen build test run clean

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
