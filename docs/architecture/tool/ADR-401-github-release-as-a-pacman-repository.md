---
status: Accepted
date: 2026-08-06
deciders:
  - aaronsb
  - claude
related:
  - ADR-400
---

# ADR-401: GitHub release as a pacman repository

## Context

The v0.3.0 release day ended with the AUR's git backend down for
unannounced maintenance: the package was ready, the SSH key worked, and
the publish failed on infrastructure we don't control. The AUR is also
source-only by design — every user rebuilds, and `pacman -Syu` never
sees updates without an AUR helper in the loop.

pacman natively supports third-party binary repositories, and a GitHub
release is a static file host: `releases/latest/download/<asset>`
always resolves against the newest release. Nothing else is needed to
be a repository except a `repo-add` database sitting next to the
package.

## Decision

Each release ships its own single-package pacman repository as release
assets, published by `make repo`:

- `makepkg` builds `clicue-<ver>-<rel>-x86_64.pkg.tar.zst` from the
  tag tarball (same PKGBUILD as AUR; `options=('!debug')` because
  cargo already strips — the debug split was an empty package).
- `repo-add` generates the db; the symlinks it creates are replaced
  with real files because release assets cannot be symlinks and pacman
  fetches the bare `clicue.db` name.
- Consumers declare once in `/etc/pacman.conf`:

  ```ini
  [clicue]
  SigLevel = Optional TrustAll
  Server = https://github.com/aaronsb/clicue/releases/latest/download/
  ```

The channels are now independent make targets: `publish` (GitHub
artifacts), `repo` (pacman repository), `publish-aur` (AUR, retained
for if/when its git backend returns). `repo` deliberately does NOT use
`publish-guard`: publish packages the working tree, so HEAD must sit
exactly at the tag; repo builds from the tag tarball makepkg downloads,
so only the version bookkeeping (Cargo.toml = pkgver, tag exists) has
to agree.

## Consequences

- `pacman -Syu` follows clicue releases with no AUR and no helper; the
  db always describes exactly one version, the latest — old packages
  fall out of the repo but remain downloadable on their releases.
- x86_64 only, matching what the release machine builds; the PKGBUILD's
  aarch64 claim is served by the source paths (AUR, makepkg), not this
  repo.
- `SigLevel Optional TrustAll` trades signature verification for zero
  key distribution; transport trust is HTTPS + GitHub. Signing packages
  with the release GPG key (and `SigLevel = Required`) is the upgrade
  path if the audience ever exceeds people who already trust the repo.
- A release is not fully published until BOTH `publish` and `repo` have
  run; the release flow's checklist gains a step.
