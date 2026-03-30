BLIP_ROOT := $(shell cd .. && pwd)
BUILD_DIR := build
APP_NAME := BLAR Archive
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
SWIFT_FILES := $(wildcard BlarArchive/*.swift)
BRIDGING_HEADER := BlarArchive/BlarArchive-Bridging-Header.h
LIBBLIP := $(BLIP_ROOT)/zig-out/lib/libblip.a
BLIP_HEADER := $(BLIP_ROOT)/src/blip.h
ASSETS := BlarArchive/Assets.xcassets
INFO_PLIST := BlarArchive/Info.plist
DOC_ICON := BlarArchive/Assets.xcassets/DocumentIcon.icns

# Detect SDK path and architecture
SDK := $(shell xcrun --show-sdk-path)
ARCH := $(shell uname -m)

# Find Nix-provided library paths for libjxl, zlib, etc.
# These are set by nix develop via NIX_LDFLAGS / NIX_CFLAGS_COMPILE
JXL_LIB_PATH := $(shell nix develop $(BLIP_ROOT) -c sh -c 'echo $$NIX_LDFLAGS' 2>/dev/null | tr ' ' '\n' | grep -oP '(?<=-L).*jxl.*' | head -1)
ZLIB_LIB_PATH := $(shell nix develop $(BLIP_ROOT) -c sh -c 'echo $$NIX_LDFLAGS' 2>/dev/null | tr ' ' '\n' | grep -oP '(?<=-L).*zlib.*' | head -1)

.PHONY: all clean libblip

all: $(APP_BUNDLE)

libblip:
	cd $(BLIP_ROOT) && nix develop -c zig build

$(LIBBLIP): libblip

$(APP_BUNDLE): $(SWIFT_FILES) $(LIBBLIP) $(INFO_PLIST) $(DOC_ICON)
	@echo "Building $(APP_NAME)..."
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"

	# Compile Swift → executable (inside nix develop for library paths)
	nix develop $(BLIP_ROOT) -c swiftc \
		-o "$(APP_BUNDLE)/Contents/MacOS/BlarArchive" \
		-import-objc-header $(BRIDGING_HEADER) \
		-I $(BLIP_ROOT)/src \
		-L $(BLIP_ROOT)/zig-out/lib \
		-lblip \
		-ljxl -ljxl_threads \
		-lz \
		-sdk $(SDK) \
		-target $(ARCH)-apple-macosx13.0 \
		-framework Cocoa \
		-framework Security \
		$(SWIFT_FILES)

	# Copy Info.plist
	@cp $(INFO_PLIST) "$(APP_BUNDLE)/Contents/"

	# Compile asset catalog
	@xcrun actool $(ASSETS) \
		--compile "$(APP_BUNDLE)/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 13.0 \
		--app-icon AppIcon \
		--output-partial-info-plist /dev/null \
		2>/dev/null || true

	# Copy document icon
	@cp $(DOC_ICON) "$(APP_BUNDLE)/Contents/Resources/"

	# Copy blar CLI into bundle for extraction
	@cp $(BLIP_ROOT)/zig-out/bin/blar "$(APP_BUNDLE)/Contents/MacOS/" 2>/dev/null || true

	@echo "Built: $(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)

install: $(APP_BUNDLE)
	cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed to /Applications/"

run: $(APP_BUNDLE)
	open "$(APP_BUNDLE)"
