SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT := Wyla.xcodeproj
SCHEME := Wyla
DERIVED_DATA := build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/Wyla.app
CORE := Packages/WylaCore
XCODEGEN := .tools/xcodegen/xcodegen/bin/xcodegen
SWIFTLINT := .tools/swiftlint/swiftlint
SWIFT_SOURCES := App Agent $(CORE)/Package.swift $(CORE)/Sources $(CORE)/Tests scripts/hwprobe.swift
JSCPD_VERSION := 5.4.3
MIN_COVERAGE ?= 80
XCODEBUILD_FLAGS ?=
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED_DATA) -showBuildTimingSummary $(XCODEBUILD_FLAGS)
VERSION ?= dev

.PHONY: help bootstrap tools hooks generate build run test coverage lint format format-check \
	analyze duplicates qa integration-test check release-zip install uninstall uninstall-data open clean

help: ## List make targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "%-18s %s\n", $$1, $$2}'

bootstrap: tools hooks ## Install pinned build tools and the git hooks

tools: ## Install pinned XcodeGen and SwiftLint into .tools (checksums verified)
	scripts/install-tools.sh

hooks: ## Run .githooks/pre-commit before each commit
	git config core.hooksPath .githooks

generate: tools ## Generate Wyla.xcodeproj from project.yml
	$(XCODEGEN) generate --quiet

build: generate ## Build the app (Debug); log in build/xcodebuild.log
	@mkdir -p build
	$(XCODEBUILD) build > build/xcodebuild.log || { tail -n 60 build/xcodebuild.log; exit 1; }
	@scripts/build-timing.sh build/xcodebuild.log

run: build ## Build and launch WYLA
	open "$(APP)"

test: ## Run the WylaCore tests
	swift test --package-path $(CORE)

coverage: ## Run WylaCore tests with coverage and xunit reports; fail below MIN_COVERAGE
	@mkdir -p build/test-results
	swift test --package-path $(CORE) --enable-code-coverage --xunit-output build/test-results/xunit.xml
	scripts/check-coverage.sh "$$(swift test --package-path $(CORE) --show-codecov-path)" $(MIN_COVERAGE)

lint: tools ## SwiftLint in strict mode
	$(SWIFTLINT) lint --strict --quiet

format: ## Format Swift sources in place
	swift format --in-place --recursive --parallel $(SWIFT_SOURCES)

format-check: ## Fail if any Swift source needs formatting
	swift format lint --strict --recursive --parallel $(SWIFT_SOURCES)

analyze: generate ## Clean build, then SwiftLint analyzer rules (unused declarations and imports)
	@mkdir -p build
	$(XCODEBUILD) clean build > build/xcodebuild-analyze.log || { tail -n 60 build/xcodebuild-analyze.log; exit 1; }
	@scripts/build-timing.sh build/xcodebuild-analyze.log
	$(SWIFTLINT) analyze --strict --quiet --compiler-log-path build/xcodebuild-analyze.log

duplicates: ## Detect copy-pasted code with jscpd
	npx --yes jscpd@$(JSCPD_VERSION)

qa: build ## Drive the running app through its menu and window (needs Accessibility permission)
	scripts/qa-drive.sh "$(APP)"

integration-test: ## Check the built app bundle, agent startup, and app launch (run after build)
	IntegrationTests/run.sh "$(APP)"

check: format-check lint coverage duplicates analyze integration-test ## Everything CI runs

release-zip: generate ## Build Release and zip Wyla.app into build/release (VERSION=v0.1.0)
	@mkdir -p build/release
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath build/ReleaseDerivedData $(XCODEBUILD_FLAGS) build > build/xcodebuild-release.log \
		|| { tail -n 60 build/xcodebuild-release.log; exit 1; }
	ditto -c -k --norsrc --noextattr --noacl --keepParent build/ReleaseDerivedData/Build/Products/Release/Wyla.app build/release/WYLA-$(VERSION).zip
	@echo "build/release/WYLA-$(VERSION).zip"

install: generate ## Build Release, copy WYLA into /Applications, and open it
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath build/ReleaseDerivedData $(XCODEBUILD_FLAGS) build > build/xcodebuild-release.log \
		|| { tail -n 60 build/xcodebuild-release.log; exit 1; }
	ditto --norsrc build/ReleaseDerivedData/Build/Products/Release/Wyla.app /Applications/Wyla.app
	open /Applications/Wyla.app

uninstall: ## Stop the agent and app, then remove WYLA from /Applications (keeps the log)
	scripts/uninstall.sh

uninstall-data: ## Like uninstall, and also deletes the recorded database and settings
	scripts/uninstall.sh --delete-data

open: generate ## Open the generated Xcode project
	open $(PROJECT)

clean: ## Remove build output and the generated project (keeps .tools)
	rm -rf build $(CORE)/.build $(PROJECT)
