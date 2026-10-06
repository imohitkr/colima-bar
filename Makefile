# Developer shortcuts. build.sh stays the source of truth for the app bundle.
# Run `make` or `make help` to list the targets.

SWIFT_PATHS = Sources Tests Package.swift
SHELL_SCRIPTS = scripts/*.sh build.sh

.DEFAULT_GOAL := help
.PHONY: help build test lint fmt install dmg clean check

help: ## List the targets
	@grep -E '^[a-z]+:.*## ' Makefile | sed 's/:.*## /	/' | awk -F '	' '{ printf "  %-8s %s\n", $$1, $$2 }'

build: ## Build build/ColimaBar.app
	./build.sh

test: ## Run the test suite
	swift test

lint: ## Check the Swift format and the shell scripts
	swift format lint --strict --recursive $(SWIFT_PATHS)
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck $(SHELL_SCRIPTS)"; shellcheck $(SHELL_SCRIPTS); \
	else \
		echo "shellcheck is not installed: skip the shell script check (CI runs it)."; \
	fi

fmt: ## Format the Swift code in place
	swift format format --in-place --recursive $(SWIFT_PATHS)

install: ## Build, install to ~/Applications and relaunch the app
	./build.sh install

dmg: ## Build the disk image build/ColimaBar-<version>.dmg
	./build.sh dmg

clean: ## Remove the build output
	rm -rf .build build

check: lint test ## Run lint, then the tests
