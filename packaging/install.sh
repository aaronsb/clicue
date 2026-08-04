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
#   … | CLICUE_VERSION=v0.2.1 sh    pin a release instead of latest
#   … | CLICUE_INSTALL_DIR=… sh     install somewhere else
#
# (Environment goes before `sh`, not before `curl` — before curl it
# reaches only curl.) The sha256 rides the same origin as the tarball,
# so verification proves integrity of the transfer, not authenticity
# beyond what HTTPS to github.com already gives.
#
# Arch users wanting a real pacman package: see the PKGBUILD one-liner
# in the README instead.
set -eu

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

main() {
  repo="aaronsb/clicue"
  dir="${CLICUE_INSTALL_DIR:-$HOME/.local/bin}"

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

  # Resolve the release tag from the /releases/latest redirect — no API
  # quota, no JSON shape coupling. The tarball name embeds the bare
  # version, so `releases/latest/download/…` alone cannot name it.
  tag="${CLICUE_VERSION:-}"
  if [ -z "$tag" ]; then
    final=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/$repo/releases/latest") \
      || die "could not resolve the latest release tag"
    tag=${final##*/}
    [ -n "$tag" ] && [ "$tag" != "latest" ] \
      || die "could not resolve the latest release tag (no releases yet?)"
  fi
  # Tags are v-prefixed; accept the bare spelling too.
  case "$tag" in v*) ;; *) tag="v$tag" ;; esac
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
  installed_ver=$("$dir/clicue" --version) \
    || die "installed binary failed to run — wrong platform artifact?"
  say "installed $installed_ver → $dir/clicue"

  on_path=1
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) on_path=0; say "note: $dir is not on your PATH" ;;
  esac

  say ""
  say "clicue is inert until wired in — next, run:"
  if [ "$on_path" = 1 ]; then
    say "  clicue install    # doctor-gated; shows the diff before touching your zshrc"
  else
    say "  $dir/clicue install    # doctor-gated; shows the diff before touching your zshrc"
  fi
}

# The entire script is behind main: a transfer truncated mid-stream
# executes no effect, because nothing runs until this line arrives.
main "$@"
