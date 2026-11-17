SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help format test package run

help:
	@printf '%s\n' 'Targets:' '  format   Format Swift files in Sources/ and Tests/' '  test     Run the Swift test suite' '  package  Build the installer package' '  run      Run an animation for five seconds (ANIMATION=filename optional)'

format:
	@find Sources Tests -type f -name '*.swift' -print0 | xargs -0 swift format format --in-place

test:
	swift test

package:
	Scripts/build-pkg.sh

run:
	swift build
	ANIMATION='$(ANIMATION)' python3 Scripts/run-test-animation.py
