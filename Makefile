SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help format lint test package run install uninstall

help:
	@printf '%s\n' 'Targets:' '  format   Format Swift files in Sources/ and Tests/' '  lint     Check Swift formatting' '  test     Run the Swift test suite' '  package  Build the drag-and-drop disk image' '  run      Run animations for five seconds (ANIMATIONS="a b" optional)' '  install  Build and install Nyathing.app (INSTALL_DIR=/Applications optional)' '  uninstall Remove Nyathing.app and its login agent (INSTALL_DIR=/Applications optional)'

format:
	@find Sources Tests -type f -name '*.swift' -print0 | xargs -0 swift format format --in-place

lint:
	swift format lint --strict --recursive Sources Tests

test:
	swift test

package:
	Scripts/build-dmg.sh

run:
	swift build
	ANIMATION='$(ANIMATION)' ANIMATIONS='$(ANIMATIONS)' python3 Scripts/run-test-animation.py

INSTALL_DIR ?= /Applications

install:
	swift build -c release
	mkdir -p "$(INSTALL_DIR)/Nyathing.app/Contents/MacOS" "$(INSTALL_DIR)/Nyathing.app/Contents/Resources"
	cp .build/release/nyathing "$(INSTALL_DIR)/Nyathing.app/Contents/MacOS/nyathing"
	rm -rf "$(INSTALL_DIR)/Nyathing.app/Contents/Resources/Nyathing_Nyathing.bundle"
	cp -R .build/release/Nyathing_Nyathing.bundle "$(INSTALL_DIR)/Nyathing.app/Contents/Resources/"
	swift Scripts/make-app-icon.swift assets/nyathing.png .build/Nyathing.iconset
	iconutil -c icns .build/Nyathing.iconset -o "$(INSTALL_DIR)/Nyathing.app/Contents/Resources/Nyathing.icns"
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>nyathing</string><key>CFBundleIdentifier</key><string>com.nyathing.Nyathing</string><key>CFBundleIconFile</key><string>Nyathing</string><key>CFBundleName</key><string>Nyathing</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > "$(INSTALL_DIR)/Nyathing.app/Contents/Info.plist"

uninstall:
	launchctl bootout "gui/$$(id -u)" "$$HOME/Library/LaunchAgents/com.nyathing.Nyathing.plist" 2>/dev/null || true
	rm -f "$$HOME/Library/LaunchAgents/com.nyathing.Nyathing.plist"
	rm -rf "$(INSTALL_DIR)/Nyathing.app"
	rm -rf "$${XDG_CONFIG_HOME:-$$HOME/.config}/nyathing"
	rm -rf "$${XDG_STATE_HOME:-$$HOME/.local/state}/nyathing"
