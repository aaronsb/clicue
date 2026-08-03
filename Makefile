# clicue — build and development entry points.
# The Rust rewrite lives in crates/; the frozen prototype (reference
# implementation, ADR-100) lives in prototype/ and is exercised via its own
# test suite, not built.

CARGO ?= cargo
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
ARCH := $(shell uname -m)

.PHONY: build release test check e2e demo fmt clippy proto-test install clean help package publish publish-guard

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

package: release ## Standalone tarball in dist/ (binary + license + readme, with sha256)
	rm -rf dist/clicue-$(VERSION)-linux-$(ARCH)
	mkdir -p dist/clicue-$(VERSION)-linux-$(ARCH)
	cp target/release/clicue LICENSE README.md dist/clicue-$(VERSION)-linux-$(ARCH)/
	tar -C dist -czf dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz clicue-$(VERSION)-linux-$(ARCH)
	cd dist && sha256sum clicue-$(VERSION)-linux-$(ARCH).tar.gz > clicue-$(VERSION)-linux-$(ARCH).tar.gz.sha256
	rm -rf dist/clicue-$(VERSION)-linux-$(ARCH)
	@echo "dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz"

# The gate runs BEFORE the release build (a dirty tree should fail in a
# second, not after a minute of cargo), and ties the bytes to the tag:
# `git status --porcelain` catches staged and untracked changes that
# `git diff --quiet` misses, and `describe --exact-match` is what makes
# "this artifact is what v$(VERSION) builds" actually true.
publish-guard:
	@test -z "$$(git status --porcelain)" || { echo "working tree dirty — commit first" >&2; exit 1; }
	@test "$$(git describe --exact-match --tags HEAD 2>/dev/null)" = "v$(VERSION)" \
	  || { echo "HEAD is not at v$(VERSION) — the artifact would not match the tag" >&2; exit 1; }

publish: publish-guard package ## Upload the artifact to the GitHub release, then push AUR
	gh release upload v$(VERSION) dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz.sha256 $(if $(FORCE),--clobber,)
	zsh packaging/publish-aur.zsh

clean:
	$(CARGO) clean
	rm -rf dist
