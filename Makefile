.PHONY: build clean help build-arm64 build-x86_64 build-ios-arm64 build-ios-simulator build-ios build-macos build-ios-all

.DEFAULT_GOAL := all

# Variables
GO_DIR := PangolinGo
LIB_NAME := libpangolin
ARCHIVE := $(GO_DIR)/$(LIB_NAME).a
HEADER := $(GO_DIR)/$(LIB_NAME).h
ARCHIVE_ARM64 := $(GO_DIR)/$(LIB_NAME)_arm64.a
ARCHIVE_X86_64 := $(GO_DIR)/$(LIB_NAME)_x86_64.a
ARCHIVE_IOS_ARM64 := $(GO_DIR)/$(LIB_NAME)_ios_arm64.a
ARCHIVE_IOS_SIM_ARM64 := $(GO_DIR)/$(LIB_NAME)_ios_sim_arm64.a
ARCHIVE_IOS_SIM_X86_64 := $(GO_DIR)/$(LIB_NAME)_ios_sim_x86_64.a
HEADER_ARM64 := $(GO_DIR)/$(LIB_NAME)_arm64.h
HEADER_X86_64 := $(GO_DIR)/$(LIB_NAME)_x86_64.h
HEADER_IOS_ARM64 := $(GO_DIR)/$(LIB_NAME)_ios_arm64.h
HEADER_IOS_SIM_ARM64 := $(GO_DIR)/$(LIB_NAME)_ios_sim_arm64.h
HEADER_IOS_SIM_X86_64 := $(GO_DIR)/$(LIB_NAME)_ios_sim_x86_64.h

# GOROOT preparation for patching
BUILDDIR ?= .tmp
REAL_GOROOT := $(shell go env GOROOT 2>/dev/null)
GOROOT := $(BUILDDIR)/goroot
GOROOT_ABS := $(CURDIR)/$(GOROOT)

# Platform detection (can be overridden)
PLATFORM_NAME ?= macosx
SDKROOT ?= $(shell xcrun --sdk $(PLATFORM_NAME) --show-sdk-path 2>/dev/null || echo "")

# Prepare patched GOROOT
$(GOROOT)/.prepared:
	@[ -n "$(REAL_GOROOT)" ] || (echo "Error: GOROOT not found. Please ensure Go is installed." && exit 1)
	@echo "Preparing patched GOROOT..."
	@mkdir -p "$(GOROOT)"
	@rsync -a --delete --exclude=pkg/obj/go-build "$(REAL_GOROOT)/" "$(GOROOT)/"
	@if [ -f "$(GO_DIR)/goruntime-boottime-over-monotonic.diff" ]; then \
		echo "Applying goruntime boottime patch..."; \
		cat "$(GO_DIR)/goruntime-boottime-over-monotonic.diff" | patch -p1 -f -N -r- -d "$(GOROOT)" || true; \
	fi
	@touch "$@"
	@echo "GOROOT prepared with patches"

# Default target
all: clean build

# Build both iOS (device) and macOS
build: build-ios build-macos
	@echo "Build complete: iOS (device) and macOS"

# Build the Go library as a universal C archive (arm64 + x86_64) for macOS
build-macos: $(ARCHIVE)

$(ARCHIVE): $(ARCHIVE_ARM64) $(ARCHIVE_X86_64)
	@echo "Creating universal binary for macOS..."
	@if [ -f $(ARCHIVE_ARM64) ] && [ -f $(ARCHIVE_X86_64) ]; then \
		lipo -create $(ARCHIVE_ARM64) $(ARCHIVE_X86_64) -output $(ARCHIVE); \
		cp $(HEADER_ARM64) $(HEADER); \
		echo "Universal binary created: $(ARCHIVE)"; \
	else \
		echo "Error: Failed to build one or more architectures"; \
		exit 1; \
	fi
	@echo "Build complete: $(ARCHIVE) and $(HEADER)"

# Build for arm64 (Apple Silicon macOS)
build-arm64: $(ARCHIVE_ARM64)

$(ARCHIVE_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod $(GOROOT)/.prepared
	@echo "Building Go library for macOS arm64..."
	cd $(GO_DIR) && CGO_ENABLED=1 GOROOT="$(GOROOT_ABS)" GOARCH=arm64 GOOS=darwin go build --buildmode=c-archive -o $(LIB_NAME)_arm64.a
	@echo "macOS arm64 build complete: $(ARCHIVE_ARM64)"

# Build for x86_64 (Intel macOS)
build-x86_64: $(ARCHIVE_X86_64)

$(ARCHIVE_X86_64): $(GO_DIR)/main.go $(GO_DIR)/go.mod $(GOROOT)/.prepared
	@echo "Building Go library for macOS x86_64..."
	cd $(GO_DIR) && CGO_ENABLED=1 GOROOT="$(GOROOT_ABS)" GOARCH=amd64 GOOS=darwin go build --buildmode=c-archive -o $(LIB_NAME)_x86_64.a
	@echo "macOS x86_64 build complete: $(ARCHIVE_X86_64)"

# Build for iOS device (arm64)
build-ios-arm64: $(ARCHIVE_IOS_ARM64)

$(ARCHIVE_IOS_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod $(GOROOT)/.prepared
	@echo "Building Go library for iOS arm64 (device)..."
	@SDKROOT=$$(xcrun --sdk iphoneos --show-sdk-path); \
	CC=$$(xcrun --sdk iphoneos --find clang); \
	cd $(GO_DIR) && \
	CGO_ENABLED=1 \
	GOROOT="$(GOROOT_ABS)" \
	GOARCH=arm64 \
	GOOS=ios \
	CC="$$CC" \
	CGO_CFLAGS="-isysroot $$SDKROOT -arch arm64 -miphoneos-version-min=15.0" \
	CGO_LDFLAGS="-isysroot $$SDKROOT -arch arm64 -miphoneos-version-min=15.0" \
	go build --buildmode=c-archive -o $(LIB_NAME)_ios_arm64.a
	@echo "iOS arm64 build complete: $(ARCHIVE_IOS_ARM64)"

# Build for iOS simulator arm64 (Apple Silicon Macs)
build-ios-simulator-arm64: $(ARCHIVE_IOS_SIM_ARM64)

$(ARCHIVE_IOS_SIM_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod $(GOROOT)/.prepared
	@echo "Building Go library for iOS simulator arm64..."
	@SDKROOT=$$(xcrun --sdk iphonesimulator --show-sdk-path); \
	CC=$$(xcrun --sdk iphonesimulator --find clang); \
	cd $(GO_DIR) && \
	CGO_ENABLED=1 \
	GOROOT="$(GOROOT_ABS)" \
	GOARCH=arm64 \
	GOOS=ios \
	CC="$$CC" \
	CGO_CFLAGS="-isysroot $$SDKROOT -arch arm64 -mios-simulator-version-min=15.0" \
	CGO_LDFLAGS="-isysroot $$SDKROOT -arch arm64 -mios-simulator-version-min=15.0" \
	go build --buildmode=c-archive -o $(LIB_NAME)_ios_sim_arm64.a
	@echo "iOS simulator arm64 build complete: $(ARCHIVE_IOS_SIM_ARM64)"

# Build for iOS simulator x86_64 (Intel Macs)
build-ios-simulator-x86_64: $(ARCHIVE_IOS_SIM_X86_64)

$(ARCHIVE_IOS_SIM_X86_64): $(GO_DIR)/main.go $(GO_DIR)/go.mod $(GOROOT)/.prepared
	@echo "Building Go library for iOS simulator x86_64..."
	@SDKROOT=$$(xcrun --sdk iphonesimulator --show-sdk-path); \
	CC=$$(xcrun --sdk iphonesimulator --find clang); \
	cd $(GO_DIR) && \
	CGO_ENABLED=1 \
	GOROOT="$(GOROOT_ABS)" \
	GOARCH=amd64 \
	GOOS=ios \
	CC="$$CC" \
	CGO_CFLAGS="-isysroot $$SDKROOT -arch x86_64 -mios-simulator-version-min=15.0" \
	CGO_LDFLAGS="-isysroot $$SDKROOT -arch x86_64 -mios-simulator-version-min=15.0" \
	go build --buildmode=c-archive -o $(LIB_NAME)_ios_sim_x86_64.a
	@echo "iOS simulator x86_64 build complete: $(ARCHIVE_IOS_SIM_X86_64)"

# Build iOS device only (no simulators)
build-ios: build-ios-arm64
	@echo "iOS device build complete"

# Build all iOS variants (including simulators)
build-ios-all: build-ios-arm64 build-ios-simulator-arm64 build-ios-simulator-x86_64
	@echo "All iOS builds complete (including simulators)"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -f $(ARCHIVE) $(HEADER)
	rm -f $(ARCHIVE_ARM64) $(ARCHIVE_X86_64)
	rm -f $(ARCHIVE_IOS_ARM64) $(ARCHIVE_IOS_SIM_ARM64) $(ARCHIVE_IOS_SIM_X86_64)
	rm -f $(HEADER_ARM64) $(HEADER_X86_64)
	rm -f $(HEADER_IOS_ARM64) $(HEADER_IOS_SIM_ARM64) $(HEADER_IOS_SIM_X86_64)
	rm -rf $(BUILDDIR)
	@echo "Clean complete"

# Show help
help:
	@echo "Available targets:"
	@echo "  make build                    - Build iOS (device) and macOS (universal)"
	@echo "  make build-macos              - Build the Go library as a universal C archive for macOS (arm64 + x86_64)"
	@echo "  make build-arm64              - Build only for macOS arm64 (Apple Silicon)"
	@echo "  make build-x86_64             - Build only for macOS x86_64 (Intel)"
	@echo "  make build-ios                - Build for iOS device (arm64) only"
	@echo "  make build-ios-arm64          - Build for iOS device (arm64)"
	@echo "  make build-ios-simulator-arm64 - Build for iOS simulator arm64 (Apple Silicon Macs)"
	@echo "  make build-ios-simulator-x86_64 - Build for iOS simulator x86_64 (Intel Macs)"
	@echo "  make build-ios-all            - Build all iOS variants (device + simulators)"
	@echo "  make clean                    - Remove build artifacts"
	@echo "  make help                     - Show this help message"

