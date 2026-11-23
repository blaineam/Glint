#!/bin/sh
# Builds Glint for Linux for every architecture and packages it for a release.
# Usage (from linux/): packaging/build-release.sh <version, e.g. 1.7.0 or 1.7.0-rc.1> <output dir>
#
# The package version comes from the release tag, not Cargo.toml, so .deb/.rpm metadata
# always matches what's being released. A pre-release "-rc.N" becomes "~rc.N", which
# dpkg and rpm both sort before the final version.
set -eu
version=$1
out=$2
pkg_version=$(printf '%s' "$version" | sed 's/-/~/')
export GLINT_VERSION="$version"
mkdir -p "$out"
for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl armv7-unknown-linux-musleabihf; do
    cargo zigbuild --release --locked --target "$t"
    cargo deb --no-build --no-strip --target "$t" --deb-version "$pkg_version" --output "$out/"
    cargo generate-rpm --target "$t" --set-metadata "version = \"$pkg_version\"" --output "$out/"
    arch=${t%%-*}
    stage=$(mktemp -d)/glint-linux-$arch
    mkdir -p "$stage"
    cp "target/$t/release/glint" packaging/install.sh packaging/glint.service packaging/glint.desktop res/glint.png ../LICENSE "$stage/"
    tar -C "$(dirname "$stage")" -czf "$out/glint-linux-$arch.tar.gz" "glint-linux-$arch"
done
(cd "$out" && sha256sum glint* > Glint-linux-SHA256SUMS.txt && cat Glint-linux-SHA256SUMS.txt)
