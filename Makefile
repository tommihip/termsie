# Termsie build — SwiftPM executable wrapped into a .app bundle.
CONFIG ?= release
APP_NAME = Termsie
BUILD_DIR = build
APP = $(BUILD_DIR)/$(APP_NAME).app
BIN_PATH = $(shell swift build -c $(CONFIG) --show-bin-path)

.PHONY: all build app run install clean icon

all: app

build:
	swift build -c $(CONFIG)

app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(BIN_PATH)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP)/Contents/Resources/"; fi
	@for b in "$(BIN_PATH)"/*.bundle; do [ -d "$$b" ] && cp -R "$$b" "$(APP)/Contents/Resources/" || true; done
	@echo "APPL????" > "$(APP)/Contents/PkgInfo"
	@codesign --force --sign - "$(APP)"
	@echo "Built $(APP)"

run: app
	open "$(APP)"

install: app
	@rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf $(BUILD_DIR) .build
