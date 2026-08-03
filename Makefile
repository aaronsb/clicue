# clicue — build and development entry points.
# The Rust rewrite lives in crates/; the frozen prototype (reference
# implementation, ADR-100) lives in prototype/ and is exercised via its own
# test suite, not built.

CARGO ?= cargo

.PHONY: build release test check e2e fmt clippy proto-test install clean help

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

build: ## Debug build
	$(CARGO) build

release: ## Optimised build
	$(CARGO) build --release

test: ## Rust tests
	$(CARGO) test

check: fmt clippy test ## Everything CI would run

e2e: build ## Sandboxed pty scenarios: real shell, real daemon, real keys
	zsh tests/run.zsh

fmt: ## Formatting check
	$(CARGO) fmt --all --check

clippy: ## Lints, warnings are errors
	$(CARGO) clippy --all-targets -- -D warnings

proto-test: ## Run the frozen prototype's suite (the differential oracle)
	zsh prototype/test.zsh

install: ## Install the binary from this tree
	$(CARGO) install --path crates/clicue

clean:
	$(CARGO) clean
