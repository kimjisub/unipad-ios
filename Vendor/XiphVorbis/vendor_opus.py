#!/usr/bin/env python3
"""Copy portable Opus sources from checksum-verified Xiph.Org releases.

Usage: python3 Vendor/XiphVorbis/vendor_opus.py <scratch-directory>
The reference library includes its encoder; unused functions are stripped by the
app linker. Architecture-specific assembly, optional neural models, networking,
examples and upstream tests are excluded.
"""
import hashlib
from pathlib import Path
import re
import shutil
import sys
import tarfile
import urllib.request

OPUS_VERSION = '1.6.1'
OPUS_SHA256 = '6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1'
OPUSFILE_VERSION = '0.12'
OPUSFILE_SHA256 = '118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b'


def release(name, version, digest, scratch):
    archive = scratch / f'{name}-{version}.tar.gz'
    if not archive.exists():
        urllib.request.urlretrieve(f'https://downloads.xiph.org/releases/opus/{archive.name}', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise ValueError(f'Checksum mismatch: {archive.name}')
    with tarfile.open(archive) as source:
        source.extractall(scratch, filter='data')
    return scratch / f'{name}-{version}'


def sources(root, filename, names):
    text = (root / filename).read_text().replace('\\\n', ' ')
    return [path for name in names for path in
            re.search(rf'^{name}\s*=([^\n]*)', text, re.MULTILINE).group(1).split()]


def copy(root, source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / source, target)


def main():
    scratch = Path(sys.argv[1]).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    package = Path(__file__).resolve().parent
    opus = release('opus', OPUS_VERSION, OPUS_SHA256, scratch)
    opusfile = release('opusfile', OPUSFILE_VERSION, OPUSFILE_SHA256, scratch)
    target = package / 'Sources/COpus'
    if target.exists():
        shutil.rmtree(target)
    selected = (sources(opus, 'opus_sources.mk', ['OPUS_SOURCES', 'OPUS_SOURCES_FLOAT'])
                + sources(opus, 'celt_sources.mk', ['CELT_SOURCES'])
                + sources(opus, 'silk_sources.mk', ['SILK_SOURCES', 'SILK_SOURCES_FLOAT']))
    for path in selected:
        copy(opus, path, target / path)
    for directory in ['src', 'celt', 'silk', 'silk/float', 'include']:
        for header in (opus / directory).glob('*.h'):
            copy(opus, header.relative_to(opus), target / header.relative_to(opus))
    copy(opus, 'COPYING', package / 'COPYING.libopus')
    target = package / 'Sources/COpusFile'
    if target.exists():
        shutil.rmtree(target)
    for path in ['src/info.c', 'src/internal.c', 'src/internal.h', 'src/opusfile.c', 'src/stream.c']:
        copy(opusfile, path, target / Path(path).name)
    copy(opusfile, 'include/opusfile.h', target / 'include/opusfile.h')
    copy(opusfile, 'COPYING', package / 'COPYING.libopusfile')


if __name__ == '__main__':
    main()
