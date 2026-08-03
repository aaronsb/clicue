#!/usr/bin/env zsh
# Publish the AUR package from packaging/aur/ — invoked by `make publish`.
# Idempotent per version: verifies pkgver against Cargo.toml, verifies the
# COMMITTED checksums against the GitHub tag tarball (an immutable tag
# whose tarball changed is an alarm, never a silent re-sum — on a version
# bump, edit pkgver and run `updpkgsums` in packaging/aur/ before
# publishing), test-builds with makepkg, regenerates .SRCINFO, pushes.
# Needs an AUR-registered SSH key in the agent; ssh is BatchMode so a
# missing key fails fast instead of hanging, accept-new so a first-ever
# contact with aur.archlinux.org does not die on an unknown host key.
set -euo pipefail

root=${0:a:h:h}
ver=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)
pkgver=$(sed -n 's/^pkgver=//p' "$root/packaging/aur/PKGBUILD")

if [[ "$ver" != "$pkgver" ]]; then
  print -u2 "PKGBUILD pkgver=$pkgver but Cargo.toml version=$ver — bump packaging/aur/PKGBUILD (and updpkgsums) first"
  exit 1
fi
if ! git -C "$root" rev-parse -q --verify "refs/tags/v$ver" >/dev/null; then
  print -u2 "tag v$ver does not exist — tag and push the release first"
  exit 1
fi

export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
work=$(mktemp -d)
cleanup() {
  if (( $? == 0 )); then
    rm -rf "$work"
  else
    print -u2 "build tree kept for inspection: $work"
  fi
}
trap cleanup EXIT INT TERM

print "── cloning AUR repo (empty on first publish) ──"
git clone "ssh://aur@aur.archlinux.org/clicue.git" "$work/clicue"

cp "$root/packaging/aur/PKGBUILD" "$root/packaging/aur/clicue.install" "$work/clicue/"
cd "$work/clicue"

print "── verifying the committed checksum against the tag tarball ──"
makepkg --verifysource --noconfirm

print "── test build (makepkg: build, package, unit tests) ──"
makepkg --cleanbuild --force --noconfirm

makepkg --printsrcinfo > .SRCINFO

git add PKGBUILD .SRCINFO clicue.install
if git diff --cached --quiet; then
  print "AUR already current at v$ver — nothing to push"
  exit 0
fi
git commit -m "clicue v$ver"
git push origin HEAD:master
print "── published: https://aur.archlinux.org/packages/clicue ──"
