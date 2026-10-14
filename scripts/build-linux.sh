#!/usr/bin/env bash
#
# Builds Termsie for Linux and stages an installable tree in dist/linux/<arch>/termsie, then
# packs it as a tarball.
#
#   1. swift build, release, with the Swift runtime and Foundation linked in, so the binary
#      needs only the system's GTK 4, libsecret and libcurl.
#   2. Stages bin/termsie, the desktop entry, the icon and the AppStream metainfo under
#      share/, the layout `cp -r` into /usr/local or ~/.local installs.
#   3. Packs Termsie-<version>-linux-<arch>.tar.gz and its SHA-256 beside the tree.
#
# Requires the Swift toolchain for Linux and the GTK 4 and libsecret development packages
# (libgtk-4-dev, libsecret-1-dev on Debian and Ubuntu).
#
#     ./scripts/build-linux.sh                  # release
#     ./scripts/build-linux.sh --configuration debug
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONFIG=release
while [ $# -gt 0 ]; do
  case "$1" in
    --configuration) CONFIG="$2"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n==> %s\n' "$1"; }
VERSION=$(sed -n 's/.*static let version = "\([0-9.]*\)".*/\1/p' Sources/TermsieCore/Support/Platform.swift)
ARCH=$(uname -m)
say "Termsie $VERSION, $CONFIG, $ARCH"

say "swift build"
swift build -c "$CONFIG" --product Termsie --static-swift-stdlib
BIN="$(swift build -c "$CONFIG" --product Termsie --static-swift-stdlib --show-bin-path)/Termsie"

STAGE="$ROOT/dist/linux/$ARCH/termsie"
say "Staging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/applications" "$STAGE/share/icons/hicolor/1024x1024/apps" "$STAGE/share/metainfo" \
         "$STAGE/share/doc/termsie"
cp "$BIN" "$STAGE/bin/termsie"
# Debug information is most of a Swift binary; the runtime's type metadata survives a strip.
if [ "$CONFIG" = release ] && command -v strip >/dev/null; then strip --strip-unneeded "$STAGE/bin/termsie"; fi
cp Resources/Linux/com.termsie.app.desktop "$STAGE/share/applications/"
cp docs/icon.png "$STAGE/share/icons/hicolor/1024x1024/apps/com.termsie.app.png"
sed "s/@VERSION@/$VERSION/; s/@DATE@/$(date +%Y-%m-%d)/" Resources/Linux/com.termsie.app.metainfo.xml \
  > "$STAGE/share/metainfo/com.termsie.app.metainfo.xml"
cp LICENSE "$STAGE/share/doc/termsie/"
echo "  needs: $(ldd "$STAGE/bin/termsie" | grep -oE 'lib(gtk-4|secret-1|curl|xml2)[^ ]*' | sort -u | tr '\n' ' ')"

if [ "$CONFIG" = release ]; then
  say "Packing"
  TAR="$ROOT/dist/linux/Termsie-$VERSION-linux-$ARCH.tar.gz"
  tar -C "$ROOT/dist/linux/$ARCH" -czf "$TAR" termsie
  (cd "$ROOT/dist/linux" && sha256sum "$(basename "$TAR")" > "SHA256SUMS-linux-$ARCH.txt")
  echo "  $TAR ($(du -h "$TAR" | cut -f1))"
fi
say "Built $STAGE"
