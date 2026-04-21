# MWB Client macOS

# Build configuration
PROJECT = MWBClient.xcodeproj
SCHEME = MWBClient
CONFIG = Debug
BUILD_DIR = ./build

.PHONY: build clean run open generate

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
