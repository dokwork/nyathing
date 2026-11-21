SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help format lint test archive run install uninstall reinstall

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  format           Format Swift files in Sources/ and Tests/' \
	  '  lint             Check Swift formatting' \
	  '  test             Run the Swift test suite' \
	  '  archive          Build a downloadable CLI archive' \
	  '  run              Run animations for five seconds (ANIMATIONS="a b" optional)' \
	  '  install          Build and install the CLI in $(PREFIX)/bin' \
	  '  uninstall        Remove the CLI and legacy app (keeps user data)' \
	  '  reinstall        Reinstall Nyathing using the selected PREFIX'

format:
	@find Sources Tests -type f -name '*.swift' -print0 | xargs -0 swift format format --in-place

lint:
	swift format lint --strict --recursive Sources Tests

test:
	swift test

archive:
	bash Scripts/package-cli.sh

PREFIX ?= /usr/local

install:
	PREFIX='$(PREFIX)' bash Scripts/install-cli.sh

uninstall:
	PREFIX='$(PREFIX)' bash Scripts/force-uninstall.sh

reinstall: uninstall install

run:
	swift build
	ANIMATION='$(ANIMATION)' ANIMATIONS='$(ANIMATIONS)' python3 Scripts/run-test-animation.py
