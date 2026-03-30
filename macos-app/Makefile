BLIP_ROOT := $(shell cd .. && pwd)
BUILD_DIR := build
APP_NAME := BLAR Archive
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
SWIFT_FILES := $(wildcard BlarArchive/*.swift)
BRIDGING_HEADER := BlarArchive/BlarArchive-Bridging-Header.h
LIBBLIP := $(BLIP_ROOT)/zig-out/lib/libblip.a
ASSETS := BlarArchive/Assets.xcassets
INFO_PLIST := BlarArchive/Info.plist
DOC_ICON := BlarArchive/Assets.xcassets/DocumentIcon.icns

SDK := $(shell xcrun --show-sdk-path)
ARCH := $(shell uname -m)

# Zig build also produces lz4 and zstd static libs alongside libblip.a
# (they're in .zig-cache but linked into the compilation graph)
# We need to find the Zig-built static libs for LZ4 and ZSTD
ZIG_CACHE := $(BLIP_ROOT)/.zig-cache

.PHONY: all clean libblip run install

all: $(APP_BUNDLE)

# Build libblip.a and all dependent static libs via Zig
libblip:
	cd $(BLIP_ROOT) && zig build

$(LIBBLIP): libblip

# Build script that runs inside nix develop for correct library paths
$(APP_BUNDLE): $(SWIFT_FILES) $(INFO_PLIST) $(DOC_ICON)
	@echo "Building $(APP_NAME)..."
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"

	# Build libblip first
	cd $(BLIP_ROOT) && zig build

	# Find Zig-built static libs for LZ4 and ZSTD in the cache
	$(eval LZ4_LIB := $(shell find $(ZIG_CACHE) -name "liblz4.a" -newer $(LIBBLIP) 2>/dev/null | head -1))
	$(eval ZSTD_LIB := $(shell find $(ZIG_CACHE) -name "libzstd.a" -newer $(LIBBLIP) 2>/dev/null | head -1))

	# If not found with -newer, try without
	$(if $(LZ4_LIB),,$(eval LZ4_LIB := $(shell find $(ZIG_CACHE) -name "liblz4.a" 2>/dev/null | head -1)))
	$(if $(ZSTD_LIB),,$(eval ZSTD_LIB := $(shell find $(ZIG_CACHE) -name "libzstd.a" 2>/dev/null | head -1)))

	@echo "LZ4: $(LZ4_LIB)"
	@echo "ZSTD: $(ZSTD_LIB)"

	# Compile Swift → executable
	# Use xcrun to find the right clang/swift that matches the SDK
	swiftc \
		-o "$(APP_BUNDLE)/Contents/MacOS/BlarArchive" \
		-import-objc-header $(BRIDGING_HEADER) \
		-I $(BLIP_ROOT)/src \
		$(LIBBLIP) \
		$(LZ4_LIB) \
		$(ZSTD_LIB) \
		-ljxl -ljxl_threads \
		-lz -lbrotlienc -lbrotlidec -lbrotlicommon -lhwy \
		-lc++ \
		-sdk $(SDK) \
		-target $(ARCH)-apple-macosx14.0 \
		-framework Cocoa \
		-framework Security \
		$(SWIFT_FILES)

	# Copy Info.plist
	@cp $(INFO_PLIST) "$(APP_BUNDLE)/Contents/"

	# Compile asset catalog
	@xcrun actool $(ASSETS) \
		--compile "$(APP_BUNDLE)/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 14.0 \
		--app-icon AppIcon \
		--output-partial-info-plist /dev/null \
		2>/dev/null || true

	# Copy document icon
	@cp $(DOC_ICON) "$(APP_BUNDLE)/Contents/Resources/"

	# Copy blar CLI into bundle (for extraction until FFI extraction is ready)
	@cp $(BLIP_ROOT)/zig-out/bin/blar "$(APP_BUNDLE)/Contents/MacOS/" 2>/dev/null || true

	@echo "Built: $(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)

install: $(APP_BUNDLE)
	cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed to /Applications/"

run: $(APP_BUNDLE)
	open "$(APP_BUNDLE)"
