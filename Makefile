# MWB Client macOS

# Build configuration
PROJECT = MWBClient.xcodeproj
SCHEME = MWBClient
CONFIG = Debug
BUILD_DIR = ./build

# Local signing identity. The Accessibility permission (TCC) is bound to this
# certificate, so every install must re-sign with the SAME identity — signing
# ad-hoc breaks the existing permission grant.
SIGN_IDENTITY ?= MWBClient Dev
INSTALLED_APP = /Applications/MWBClient.app

.PHONY: build clean run open generate install

generate:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' \
		-configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		SYMROOT=$(BUILD_DIR)/Products \
		build

clean:
	rm -rf $(BUILD_DIR)

run: build
	open $(BUILD_DIR)/Products/$(CONFIG)/MWBClient.app

open:
	open $(BUILD_DIR)/Products/$(CONFIG)/MWBClient.app

# SPM-based install for machines without full Xcode. Builds release, replaces
# the binary inside the installed bundle and re-signs with SIGN_IDENTITY.
install:
	swift build -c release
	-osascript -e 'quit app "MWBClient"' >/dev/null 2>&1 || true
	-pkill -x MWBClient >/dev/null 2>&1 || true
	-sleep 1
	cp .build/release/MWBClient $(INSTALLED_APP)/Contents/MacOS/MWBClient
	codesign --force --options runtime -s "$(SIGN_IDENTITY)" $(INSTALLED_APP)
	open $(INSTALLED_APP)
