# Developer shortcuts. build.sh stays the source of truth for the app bundle.
# Run `make` or `make help` to list the targets.

SWIFT_PATHS = Sources Tests Package.swift
SHELL_SCRIPTS = scripts/*.sh build.sh

# The same pinned images as CI (.github/workflows/ci.yml). Update both places together.
SHELLCHECK_IMAGE = koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
ACTIONLINT_IMAGE = rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667

# $(call run-tool,name,image,args): use the local binary if it is installed.
# Else use the pinned image if docker works. Else skip with a notice.
define run-tool
	@if command -v $(1) >/dev/null 2>&1; then \
		echo "$(1) $(3)"; $(1) $(3); \
	elif docker info >/dev/null 2>&1; then \
		echo "docker run $(2) $(3)"; \
		docker run --rm -v "$(CURDIR):/src:ro" -w /src $(2) $(3); \
	else \
		echo "$(1) and docker are not available: skip the $(1) check (CI runs it)."; \
	fi
endef

.DEFAULT_GOAL := help
.PHONY: help build test lint fmt install dmg clean check

help: ## List the targets
	@grep -E '^[a-z]+:.*## ' Makefile | sed 's/:.*## /	/' | awk -F '	' '{ printf "  %-8s %s\n", $$1, $$2 }'

build: ## Build build/ColimaBar.app
	./build.sh

test: ## Run the test suite
	swift test

lint: ## Check the Swift format, shell scripts and workflows
	swift format lint --strict --recursive $(SWIFT_PATHS)
	$(call run-tool,shellcheck,$(SHELLCHECK_IMAGE),$(SHELL_SCRIPTS))
	$(call run-tool,actionlint,$(ACTIONLINT_IMAGE),)

fmt: ## Format the Swift code in place
	swift format format --in-place --recursive $(SWIFT_PATHS)

install: ## Build, install to ~/Applications and relaunch the app
	./build.sh install

dmg: ## Build the disk image build/ColimaBar-<version>.dmg
	./build.sh dmg

clean: ## Remove the build output
	rm -rf .build build

check: lint test ## Run lint, then the tests
