#!/usr/bin/env zsh
# Publish the AUR package from packaging/aur/ — invoked by `make publish`.
# Idempotent per version: verifies pkgver against Cargo.toml, refreshes
# checksums from the GitHub tag tarball, test-builds with makepkg,
# regenerates .SRCINFO, and pushes. Needs an AUR-registered SSH key in
# the agent; every ssh use is BatchMode so a missing key fails fast
# instead of hanging.
set -euo pipefail
setopt errexit

root=${0:a:h:h}
ver=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)
pkgver=$(sed -n 's/^pkgver=//p' "$root/packaging/aur/PKGBUILD")

if [[ "$ver" != "$pkgver" ]]; then
  print -u2 "PKGBUILD pkgver=$pkgver but Cargo.toml version=$ver — bump packaging/aur/PKGBUILD first"
  exit 1
fi
if ! git -C "$root" rev-parse -q --verify "refs/tags/v$ver" >/dev/null; then
  print -u2 "tag v$ver does not exist — tag and push the release first"
  exit 1
fi

export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

print "── cloning AUR repo (empty on first publish) ──"
git clone "ssh://aur@aur.archlinux.org/clicue.git" "$work/clicue"

cp "$root/packaging/aur/PKGBUILD" "$root/packaging/aur/clicue.install" "$work/clicue/"
cd "$work/clicue"

print "── refreshing checksums from the GitHub tag tarball ──"
updpkgsums

print "── test build (makepkg: fetch, build, package, unit tests) ──"
makepkg --cleanbuild --force --noconfirm

makepkg --printsrcinfo > .SRCINFO

# Mirror the refreshed sums back so the repo copy stays the truth.
cp PKGBUILD "$root/packaging/aur/PKGBUILD"

git add PKGBUILD .SRCINFO clicue.install
if git diff --cached --quiet; then
  print "AUR already current at v$ver — nothing to push"
  exit 0
fi
git commit -m "clicue v$ver"
git push origin HEAD:master
print "── published: https://aur.archlinux.org/packages/clicue ──"
