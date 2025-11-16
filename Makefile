.PHONY: build clean help build-arm64 build-x86_64

# Variables
GO_DIR := PangolinGo
LIB_NAME := libpangolin
ARCHIVE := $(GO_DIR)/$(LIB_NAME).a
HEADER := $(GO_DIR)/$(LIB_NAME).h
ARCHIVE_ARM64 := $(GO_DIR)/$(LIB_NAME)_arm64.a
ARCHIVE_X86_64 := $(GO_DIR)/$(LIB_NAME)_x86_64.a
HEADER_ARM64 := $(GO_DIR)/$(LIB_NAME)_arm64.h
HEADER_X86_64 := $(GO_DIR)/$(LIB_NAME)_x86_64.h

# Default target
all: build

# Build the Go library as a universal C archive (arm64 + x86_64)
build: $(ARCHIVE)

$(ARCHIVE): $(ARCHIVE_ARM64) $(ARCHIVE_X86_64)
	@echo "Creating universal binary..."
	@if [ -f $(ARCHIVE_ARM64) ] && [ -f $(ARCHIVE_X86_64) ]; then \
		lipo -create $(ARCHIVE_ARM64) $(ARCHIVE_X86_64) -output $(ARCHIVE); \
		cp $(HEADER_ARM64) $(HEADER); \
		echo "Universal binary created: $(ARCHIVE)"; \
	else \
		echo "Error: Failed to build one or more architectures"; \
		exit 1; \
	fi
	@echo "Build complete: $(ARCHIVE) and $(HEADER)"

# Build for arm64 (Apple Silicon)
build-arm64: $(ARCHIVE_ARM64)

$(ARCHIVE_ARM64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for arm64..."
	cd $(GO_DIR) && CGO_ENABLED=1 GOARCH=arm64 GOOS=darwin go build --buildmode=c-archive -o $(LIB_NAME)_arm64.a
	@echo "arm64 build complete: $(ARCHIVE_ARM64)"

# Build for x86_64 (Intel)
build-x86_64: $(ARCHIVE_X86_64)

$(ARCHIVE_X86_64): $(GO_DIR)/main.go $(GO_DIR)/go.mod
	@echo "Building Go library for x86_64..."
	cd $(GO_DIR) && CGO_ENABLED=1 GOARCH=amd64 GOOS=darwin go build --buildmode=c-archive -o $(LIB_NAME)_x86_64.a
	@echo "x86_64 build complete: $(ARCHIVE_X86_64)"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -f $(ARCHIVE) $(HEADER)
	rm -f $(ARCHIVE_ARM64) $(ARCHIVE_X86_64)
	rm -f $(HEADER_ARM64) $(HEADER_X86_64)
	@echo "Clean complete"

# Show help
help:
	@echo "Available targets:"
	@echo "  make build      - Build the Go library as a universal C archive (arm64 + x86_64)"
	@echo "  make build-arm64   - Build only for arm64 (Apple Silicon)"
	@echo "  make build-x86_64  - Build only for x86_64 (Intel)"
	@echo "  make clean      - Remove build artifacts"
	@echo "  make help       - Show this help message"

