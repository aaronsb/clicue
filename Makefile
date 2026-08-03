# clicue — build and development entry points.
# The Rust rewrite lives in crates/; the frozen prototype (reference
# implementation, ADR-100) lives in prototype/ and is exercised via its own
# test suite, not built.

CARGO ?= cargo

.PHONY: build release test check e2e demo fmt clippy proto-test install clean help

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

demo: build ## Record docs/demo/clicue.cast (+ .gif when agg is installed)
	asciinema rec --overwrite --cols 84 --rows 26 -c "zsh docs/demo/record.zsh" docs/demo/clicue.cast
	@command -v agg >/dev/null 2>&1 \
	  && agg --font-size 14 docs/demo/clicue.cast docs/demo/clicue.gif \
	  || echo "agg not installed — .cast only"

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
