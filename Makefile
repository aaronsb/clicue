# clicue — build and development entry points.
# The Rust rewrite lives in crates/; the frozen prototype (reference
# implementation, ADR-100) lives in prototype/ and is exercised via its own
# test suite, not built.

CARGO ?= cargo
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
ARCH := $(shell uname -m)

.PHONY: build release test check e2e demo fmt clippy proto-test install clean help package publish publish-guard repo repo-guard publish-aur

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
	asciinema rec --overwrite --window-size 100x26 -c "zsh docs/demo/record.zsh" docs/demo/clicue.cast
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

publish: publish-guard package ## Upload artifacts to the GitHub release
	# The release-asset PKGBUILD carries a REAL checksum — unlike the repo
	# copy (SKIP by design), an asset is not inside the tarball it sums, so
	# no circularity. `makepkg` against these two files is the no-AUR path.
	cp packaging/aur/PKGBUILD packaging/aur/clicue.install dist/
	cd dist && updpkgsums PKGBUILD
	gh release upload v$(VERSION) dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz.sha256 dist/PKGBUILD dist/clicue.install $(if $(FORCE),--clobber,)

# Unlike publish (which packages the working tree, hence the full guard),
# repo builds from the TAG TARBALL makepkg downloads — HEAD may sit past
# the tag; only the version bookkeeping has to agree (ADR-401).
repo-guard:
	@test "$$(sed -n 's/^pkgver=//p' packaging/aur/PKGBUILD)" = "$(VERSION)" \
	  || { echo "PKGBUILD pkgver != Cargo.toml $(VERSION) — bump packaging/aur/PKGBUILD first" >&2; exit 1; }
	@git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null \
	  || { echo "tag v$(VERSION) does not exist — tag and push the release first" >&2; exit 1; }

repo: repo-guard ## Build the pacman package + [clicue] repo db, upload to the GitHub release
	# The GitHub release doubles as a pacman repository (ADR-401):
	# Server = https://github.com/aaronsb/clicue/releases/latest/download/
	# Each release ships a fresh single-package db, so `pacman -Syu`
	# follows the latest release with no AUR in the path.
	rm -rf dist/repo
	mkdir -p dist/repo
	cp packaging/aur/PKGBUILD packaging/aur/clicue.install dist/repo/
	cd dist/repo && updpkgsums PKGBUILD && makepkg -f
	cd dist/repo && repo-add clicue.db.tar.gz clicue-$(VERSION)-*-$(ARCH).pkg.tar.zst
	# Release assets cannot be symlinks, and pacman fetches the BARE names
	# (clicue.db) — replace repo-add's symlinks with real files.
	cd dist/repo && rm -f clicue.db clicue.files \
	  && cp clicue.db.tar.gz clicue.db && cp clicue.files.tar.gz clicue.files
	gh release upload v$(VERSION) \
	  dist/repo/clicue-$(VERSION)-*-$(ARCH).pkg.tar.zst \
	  dist/repo/clicue.db dist/repo/clicue.db.tar.gz \
	  dist/repo/clicue.files dist/repo/clicue.files.tar.gz \
	  $(if $(FORCE),--clobber,)

publish-aur: ## Push the PKGBUILD to AUR (independent channel; its script self-guards)
	zsh packaging/publish-aur.zsh

clean:
	$(CARGO) clean
	rm -rf dist
