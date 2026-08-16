# clicue — build and development entry points.
# The Rust rewrite lives in crates/; the frozen prototype (reference
# implementation, ADR-100) lives in prototype/ and is exercised via its own
# test suite, not built.

CARGO ?= cargo
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
ARCH := $(shell uname -m)

.PHONY: build build-release test check e2e e2e-release demo fmt clippy proto-test \
        install clean help dist package release release-guard version

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

build: ## Debug build
	$(CARGO) build

build-release: ## Optimised build
	$(CARGO) build --release

test: ## Rust tests
	$(CARGO) test

check: fmt clippy test ## Everything CI would run

e2e: build ## Sandboxed pty scenarios: real shell, real daemon, real keys
	zsh tests/run.zsh

# CI runs this variant: a contended runner VM with a debug daemon misses
# the shim's 25ms deadline and cards go absent BY DESIGN (spec §8) —
# test the binary users actually run.
e2e-release: build-release ## e2e against the release binary (what CI runs)
	CLICUE_BIN=$(CURDIR)/target/release/clicue zsh tests/run.zsh

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

dist: build-release ## Standalone tarball in dist/ (binary + license + readme, with sha256)
	rm -rf dist pkgbuild-check/clicue-$(VERSION)-linux-$(ARCH)
	mkdir -p dist/clicue-$(VERSION)-linux-$(ARCH)
	cp target/release/clicue LICENSE README.md dist/clicue-$(VERSION)-linux-$(ARCH)/
	tar -C dist -czf dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz clicue-$(VERSION)-linux-$(ARCH)
	cd dist && sha256sum clicue-$(VERSION)-linux-$(ARCH).tar.gz > clicue-$(VERSION)-linux-$(ARCH).tar.gz.sha256
	rm -rf dist pkgbuild-check/clicue-$(VERSION)-linux-$(ARCH)
	@echo "dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz"

# The gate runs BEFORE the release build (a dirty tree should fail in a
# second, not after a minute of cargo), and ties the bytes to the tag:
# `git status --porcelain` catches staged and untracked changes that
# `git diff --quiet` misses, and `describe --exact-match` is what makes
# "this artifact is what v$(VERSION) builds" actually true.
release-guard:
	@test -z "$$(git status --porcelain)" || { echo "working tree dirty — commit first" >&2; exit 1; }
	@test "$$(git describe --exact-match --tags HEAD 2>/dev/null)" = "v$(VERSION)" \
	  || { echo "HEAD is not at v$(VERSION) — the artifact would not match the tag" >&2; exit 1; }

release: release-guard dist ## Cut the release arch-repo reads
	# The standalone tarball stays: it is the no-pacman path for anyone who
	# wants the binary without a repository. The PKGBUILD and clicue.install
	# used to be uploaded alongside it as a makepkg-without-AUR route, and
	# arch-repo is that route now — it publishes this recipe to the AUR and to
	# [aaronsb] from the default branch.
	gh release upload v$(VERSION) \
	  dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz \
	  dist/clicue-$(VERSION)-linux-$(ARCH).tar.gz.sha256 $(if $(FORCE),--clobber,)
	@echo "arch-repo picks this up on its next run"

version: ## Report the version this repository would release
	@test -n "$(VERSION)" || { echo "no version in Cargo.toml" >&2; exit 1; }
	@if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null; then \
	    echo "clicue $(VERSION) — v$(VERSION) is already tagged"; \
	else \
	    echo "clicue $(VERSION) — not yet tagged; this is what the next release will be"; \
	fi

package: version ## Build ./PKGBUILD in a clean chroot and namcap it
	@command -v extra-x86_64-build >/dev/null || { echo "needs devtools" >&2; exit 1; }
	@command -v namcap >/dev/null            || { echo "needs namcap" >&2; exit 1; }
	rm -rf pkgbuild-check && mkdir -p pkgbuild-check
	# The tarball the release would carry, built from HEAD and named exactly
	# what source= resolves to, so makepkg uses it instead of fetching
	# archive/v$$pkgver.tar.gz — which GitHub does not generate until the tag
	# exists. HEAD, not the working tree: a release ships a commit.
	git archive --format=tar.gz --prefix=clicue-$(VERSION)/ \
	    -o pkgbuild-check/clicue-$(VERSION).tar.gz HEAD
	cp PKGBUILD clicue.install pkgbuild-check/
	# Slot one only, the entry that moves with the version and the one
	# arch-repo writes. The sums array is the only quoted 64-hex in a recipe.
	cd pkgbuild-check \
	  && sed -i 's/^pkgver=.*/pkgver=$(VERSION)/' PKGBUILD \
	  && sum=$$(sha256sum clicue-$(VERSION).tar.gz | cut -d' ' -f1) \
	  && sed -i "0,/'[0-9a-f]\{64\}'/s//'$$sum'/" PKGBUILD
	cd pkgbuild-check && extra-x86_64-build
	# namcap exits 0 whether or not it found errors, so its output decides —
	# the same rule arch-repo's gate uses.
	cd pkgbuild-check && namcap PKGBUILD $$(ls ./*.pkg.tar.zst | grep -v -- '-debug-') | tee namcap.txt
	@cd pkgbuild-check && bad=$$(grep ' E: ' namcap.txt || true); \
	  if [ -n "$$bad" ]; then echo "namcap errors:"; printf '%s\n' "$$bad"; exit 1; fi; \
	  echo "namcap: no errors"

clean:
	$(CARGO) clean
	rm -rf dist pkgbuild-check
