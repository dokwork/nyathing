SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help format lint test package run

help:
	@printf '%s\n' 'Targets:' '  format   Format Swift files in Sources/ and Tests/' '  lint     Check Swift formatting' '  test     Run the Swift test suite' '  package  Build the drag-and-drop disk image' '  run      Run animations for five seconds (ANIMATIONS="a b" optional)'

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
