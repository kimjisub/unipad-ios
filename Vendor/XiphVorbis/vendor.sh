#!/bin/bash
# Copies the Ogg Vorbis decoder sources from Xiph.Org release tarballs into Sources/.
# Only the decoder (libogg, libvorbis, libvorbisfile) is taken, not the encoder (libvorbisenc)
# or the example and test programs. The sources are as released, plus the upstream commits in
# patches/: decoder fixes Xiph.Org made after libvorbis 1.3.7, its latest release. One of them
# (28965ede) stops a few bytes of a damaged setup header from overflowing the thread's stack.
# Each patch is the commit as https://gitlab.xiph.org/xiph/vorbis/-/commit/<sha>.patch gives it;
# drop the patches a newer release already contains.
# Run it again after changing a version below, then review the diff of Sources/.
set -euo pipefail

OGG_VERSION=1.3.6
OGG_SHA256=5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061
VORBIS_VERSION=1.3.7
VORBIS_SHA256=b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b

VORBIS_SOURCES="mdct.c smallft.c block.c envelope.c window.c lsp.c lpc.c analysis.c synthesis.c
psy.c info.c floor1.c floor0.c res0.c mapping0.c registry.c codebook.c sharedbook.c lookup.c
bitrate.c vorbisfile.c"

package=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() { # name version sha256 directory
    local archive="$1-$2.tar.xz"
    curl -fsSL -o "$work/$archive" "https://downloads.xiph.org/releases/$4/$archive"
    echo "$3  $work/$archive" | shasum -a 256 -c -
    tar -xf "$work/$archive" -C "$work"
}

fetch libogg "$OGG_VERSION" "$OGG_SHA256" ogg
fetch libvorbis "$VORBIS_VERSION" "$VORBIS_SHA256" vorbis
ogg="$work/libogg-$OGG_VERSION"
vorbis="$work/libvorbis-$VORBIS_VERSION"
for fix in "$package"/patches/*.patch; do patch -d "$vorbis" -p1 --forward --quiet < "$fix"; done

rm -rf "$package/Sources"
mkdir -p "$package/Sources/COgg/include/ogg" "$package/Sources/CVorbis/include/vorbis"
cp "$ogg/src/bitwise.c" "$ogg/src/framing.c" "$ogg/src/crctable.h" "$package/Sources/COgg/"
cp "$ogg/include/ogg/ogg.h" "$ogg/include/ogg/os_types.h" "$package/Sources/COgg/include/ogg/"
for source in $VORBIS_SOURCES; do cp "$vorbis/lib/$source" "$package/Sources/CVorbis/"; done
cp "$vorbis"/lib/*.h "$package/Sources/CVorbis/"
cp "$vorbis/include/vorbis/codec.h" "$vorbis/include/vorbis/vorbisfile.h" "$package/Sources/CVorbis/include/vorbis/"
cp "$ogg/COPYING" "$package/COPYING.libogg"
cp "$vorbis/COPYING" "$package/COPYING.libvorbis"
