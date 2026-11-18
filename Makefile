PROJECT := Wyla.xcodeproj
SCHEME := Wyla
DERIVED_DATA := build/DerivedData
CORE := Packages/WylaCore
XCODEBUILD_FLAGS ?=

.PHONY: bootstrap generate build test lint check open clean

bootstrap: ## Install XcodeGen and SwiftLint
	brew install xcodegen swiftlint

generate: ## Generate Wyla.xcodeproj from project.yml
	xcodegen generate --quiet

build: generate ## Build the app (Debug)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_FLAGS) build

test: ## Run WylaCore tests
	swift test --package-path $(CORE)

lint: ## Run SwiftLint in strict mode
	swiftlint lint --strict --quiet

check: lint test build ## Everything CI runs

open: generate ## Open the generated Xcode project
	open $(PROJECT)

clean: ## Remove build output and the generated project
	rm -rf build $(CORE)/.build $(PROJECT)
