# Maintainer: Aaron Bockelie <aaronsb@gmail.com>
#
# aaronsb/arch-repo reads this file from the default branch, takes the version
# and checksum from the newest published release, builds it in a clean
# container, lints it, signs it, and pushes to the AUR and the [aaronsb] pacman
# repository. See its docs/packaging-contract.md.
#
# pkgver, pkgrel and sha256sums below are placeholders, and correct as
# placeholders — arch-repo overwrites all three. The sum used to be SKIP under
# a comment calling a committed checksum circular, which was a correct reading
# of a real problem: this file ships inside the tarball it would sum, so the
# hash cannot exist until the tag does. arch-repo resolves it by taking the
# recipe from the branch and the two moving values from the release, rather
# than by leaving the sum out.
pkgname=clicue
pkgver=0.4.0
pkgrel=1
pkgdesc="Live, contextual command guidance for zsh — a daemon behind a generated shim"
arch=('x86_64' 'aarch64')
url="https://github.com/aaronsb/clicue"
license=('MIT')
depends=('zsh' 'gcc-libs')
makedepends=('cargo')
optdepends=('man-db: glosses for system commands (whatis)')
install=clicue.install
# cargo already strips the release binary (profile.release strip=true), so
# makepkg's debug split would ship an empty -debug package — suppress it.
options=('!debug')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')

prepare() {
  cd "$pkgname-$pkgver"
  export RUSTUP_TOOLCHAIN=stable
  # All network work here, so build() runs offline in a clean chroot.
  cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')"
}

build() {
  cd "$pkgname-$pkgver"
  export RUSTUP_TOOLCHAIN=stable
  cargo build --frozen --release -p clicue
}

check() {
  cd "$pkgname-$pkgver"
  export RUSTUP_TOOLCHAIN=stable
  # --lib deliberately: the unit suite is self-contained (temp dirs, its
  # own sockets); the repo's e2e pty scenarios live outside the crate and
  # need an interactive sandbox no build chroot has. If an integration
  # suite ever lands under crates/clicue/tests/, revisit this flag —
  # today it excludes nothing but doc-tests.
  cargo test --frozen --release -p clicue --lib
}

package() {
  cd "$pkgname-$pkgver"
  install -Dm755 target/release/clicue "$pkgdir/usr/bin/clicue"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
}
