#!/bin/sh
# clicue — GitHub-release artifact installer.
#
#   curl -fsSL https://raw.githubusercontent.com/aaronsb/clicue/main/packaging/install.sh | sh
#
# Downloads the latest release's prebuilt tarball for this machine,
# verifies its published sha256, and puts the binary in
# ${CLICUE_INSTALL_DIR:-~/.local/bin}. No root, no compiler. The binary
# is INERT until `clicue install` wires it into your zshrc — this script
# never touches shell config (that separation is the point: package
# transport here, doctor-gated activation there).
#
#   CLICUE_VERSION=v0.2.1  pin a release instead of latest
#   CLICUE_INSTALL_DIR=…   install somewhere else
#
# Arch users wanting a real pacman package: see the PKGBUILD one-liner
# in the README instead.
set -eu

repo="aaronsb/clicue"
dir="${CLICUE_INSTALL_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required (coreutils)"
command -v tar >/dev/null || die "tar is required"

os=$(uname -s)
[ "$os" = "Linux" ] || die "prebuilt artifacts exist for Linux only (this is $os) — build with: cargo install --git https://github.com/$repo clicue"

arch=$(uname -m)
case "$arch" in
  x86_64) ;;
  *) die "no prebuilt artifact for $arch yet — build with: cargo install --git https://github.com/$repo clicue" ;;
esac

# Resolve the release tag. The tarball name embeds the bare version, so
# `releases/latest/download/…` alone cannot name it.
tag="${CLICUE_VERSION:-}"
if [ -z "$tag" ]; then
  tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$tag" ] || die "could not resolve the latest release tag from api.github.com"
fi
ver=${tag#v}
name="clicue-$ver-linux-$arch"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "fetching $name.tar.gz ($tag)…"
base="https://github.com/$repo/releases/download/$tag"
curl -fsSL -o "$tmp/$name.tar.gz" "$base/$name.tar.gz" \
  || die "download failed: $base/$name.tar.gz"
curl -fsSL -o "$tmp/$name.tar.gz.sha256" "$base/$name.tar.gz.sha256" \
  || die "download failed: $base/$name.tar.gz.sha256"

( cd "$tmp" && sha256sum -c "$name.tar.gz.sha256" >/dev/null ) \
  || die "sha256 mismatch — refusing to install a tarball that does not match its published checksum"
say "checksum verified."

tar -C "$tmp" -xzf "$tmp/$name.tar.gz"
[ -f "$tmp/$name/clicue" ] || die "tarball did not contain $name/clicue"

mkdir -p "$dir"
install -m 755 "$tmp/$name/clicue" "$dir/clicue"
say "installed $("$dir/clicue" --version) → $dir/clicue"

case ":$PATH:" in
  *":$dir:"*) ;;
  *) say "note: $dir is not on your PATH" ;;
esac

say ""
say "clicue is inert until wired in — next, run:"
say "  clicue install    # doctor-gated; shows the diff before touching your zshrc"
