SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help format lint test package run install-app install-cli-link install uninstall

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  format           Format Swift files in Sources/ and Tests/' \
	  '  lint             Check Swift formatting' \
	  '  test             Run the Swift test suite' \
	  '  package          Build the macOS installer package' \
	  '  run              Run animations for five seconds (ANIMATIONS="a b" optional)' \
	  '  install          Install the app and CLI symlink' \
	  '  install-app      Build and install Nyathing.app in /Applications' \
	  '  install-cli-link Create the /usr/local/bin/nyathing symlink' \
	  '  uninstall        Force-remove the app, CLI command, and user data'

format:
	@find Sources Tests -type f -name '*.swift' -print0 | xargs -0 swift format format --in-place

lint:
	swift format lint --strict --recursive Sources Tests

test:
	swift test

package:
	Scripts/build-pkg.sh

install-app:
	bash Scripts/install-app.sh

install-cli-link:
	bash Scripts/install-cli-link.sh

install: install-app install-cli-link

uninstall:
	bash Scripts/force-uninstall.sh

run:
	swift build
	ANIMATION='$(ANIMATION)' ANIMATIONS='$(ANIMATIONS)' python3 Scripts/run-test-animation.py
