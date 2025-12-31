.PHONY: build clean help build-arm64 build-x86_64 build-ios-arm64 build-ios-simulator

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

# Platform detection (can be overridden)
PLATFORM_NAME ?= macosx
SDKROOT ?= $(shell xcrun --sdk $(PLATFORM_NAME) --show-sdk-path 2>/dev/null || echo "")

# Default target
all: clean build

# Build the Go library as a universal C archive (arm64 + x86_64) for macOS
build: $(ARCHIVE)

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

$(ARCHIVE_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for macOS arm64..."
	cd $(GO_DIR) && CGO_ENABLED=1 GOARCH=arm64 GOOS=darwin go build --buildmode=c-archive -o $(LIB_NAME)_arm64.a
	@echo "macOS arm64 build complete: $(ARCHIVE_ARM64)"

# Build for x86_64 (Intel macOS)
build-x86_64: $(ARCHIVE_X86_64)

$(ARCHIVE_X86_64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for macOS x86_64..."
	cd $(GO_DIR) && CGO_ENABLED=1 GOARCH=amd64 GOOS=darwin go build --buildmode=c-archive -o $(LIB_NAME)_x86_64.a
	@echo "macOS x86_64 build complete: $(ARCHIVE_X86_64)"

# Build for iOS device (arm64)
build-ios-arm64: $(ARCHIVE_IOS_ARM64)

$(ARCHIVE_IOS_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for iOS arm64 (device)..."
	@SDKROOT=$$(xcrun --sdk iphoneos --show-sdk-path); \
	CC=$$(xcrun --sdk iphoneos --find clang); \
	cd $(GO_DIR) && \
	CGO_ENABLED=1 \
	GOARCH=arm64 \
	GOOS=ios \
	CC="$$CC" \
	CGO_CFLAGS="-isysroot $$SDKROOT -arch arm64 -miphoneos-version-min=15.0" \
	CGO_LDFLAGS="-isysroot $$SDKROOT -arch arm64 -miphoneos-version-min=15.0" \
	go build --buildmode=c-archive -o $(LIB_NAME)_ios_arm64.a
	@echo "iOS arm64 build complete: $(ARCHIVE_IOS_ARM64)"

# Build for iOS simulator arm64 (Apple Silicon Macs)
build-ios-simulator-arm64: $(ARCHIVE_IOS_SIM_ARM64)

$(ARCHIVE_IOS_SIM_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for iOS simulator arm64..."
	@SDKROOT=$$(xcrun --sdk iphonesimulator --show-sdk-path); \
	CC=$$(xcrun --sdk iphonesimulator --find clang); \
	cd $(GO_DIR) && \
	CGO_ENABLED=1 \
	GOARCH=arm64 \
	GOOS=ios \
	CC="$$CC" \
	CGO_CFLAGS="-isysroot $$SDKROOT -arch arm64 -mios-simulator-version-min=15.0" \
	CGO_LDFLAGS="-isysroot $$SDKROOT -arch arm64 -mios-simulator-version-min=15.0" \
	go build --buildmode=c-archive -o $(LIB_NAME)_ios_sim_arm64.a
	@echo "iOS simulator arm64 build complete: $(ARCHIVE_IOS_SIM_ARM64)"

# Build for iOS simulator x86_64 (Intel Macs)
build-ios-simulator-x86_64: $(ARCHIVE_IOS_SIM_X86_64)

$(ARCHIVE_IOS_SIM_X86_64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for iOS simulator x86_64..."
	@SDKROOT=$$(xcrun --sdk iphonesimulator --show-sdk-path); \
	CC=$$(xcrun --sdk iphonesimulator --find clang); \
	cd $(GO_DIR) && \
	CGO_ENABLED=1 \
	GOARCH=amd64 \
	GOOS=ios \
	CC="$$CC" \
	CGO_CFLAGS="-isysroot $$SDKROOT -arch x86_64 -mios-simulator-version-min=15.0" \
	CGO_LDFLAGS="-isysroot $$SDKROOT -arch x86_64 -mios-simulator-version-min=15.0" \
	go build --buildmode=c-archive -o $(LIB_NAME)_ios_sim_x86_64.a
	@echo "iOS simulator x86_64 build complete: $(ARCHIVE_IOS_SIM_X86_64)"

# Build all iOS variants
build-ios: build-ios-arm64 build-ios-simulator-arm64 build-ios-simulator-x86_64
	@echo "All iOS builds complete"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -f $(ARCHIVE) $(HEADER)
	rm -f $(ARCHIVE_ARM64) $(ARCHIVE_X86_64)
	rm -f $(ARCHIVE_IOS_ARM64) $(ARCHIVE_IOS_SIM_ARM64) $(ARCHIVE_IOS_SIM_X86_64)
	rm -f $(HEADER_ARM64) $(HEADER_X86_64)
	rm -f $(HEADER_IOS_ARM64) $(HEADER_IOS_SIM_ARM64) $(HEADER_IOS_SIM_X86_64)
	@echo "Clean complete"

# Show help
help:
	@echo "Available targets:"
	@echo "  make build                    - Build the Go library as a universal C archive for macOS (arm64 + x86_64)"
	@echo "  make build-arm64              - Build only for macOS arm64 (Apple Silicon)"
	@echo "  make build-x86_64             - Build only for macOS x86_64 (Intel)"
	@echo "  make build-ios-arm64          - Build for iOS device (arm64)"
	@echo "  make build-ios-simulator-arm64 - Build for iOS simulator arm64 (Apple Silicon Macs)"
	@echo "  make build-ios-simulator-x86_64 - Build for iOS simulator x86_64 (Intel Macs)"
	@echo "  make build-ios                - Build all iOS variants"
	@echo "  make clean                    - Remove build artifacts"
	@echo "  make help                     - Show this help message"

