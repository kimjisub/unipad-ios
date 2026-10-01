"""Regression for the legacy synthetic-pack selector; run before overlaying."""
import argparse
import pathlib
import zipfile

p = argparse.ArgumentParser()
p.add_argument('pack', type=pathlib.Path)
p.add_argument('--legacy', action='store_true')
a = p.parse_args()
with zipfile.ZipFile(a.pack) as z:
    info = z.read('info').decode()
title = next(line.split('=', 1)[1] for line in info.splitlines() if line.startswith('title='))
selected = ' - ' in title if a.legacy else title == 'Conformance'
assert selected, f'Legacy selector cannot select exact synthetic title {title!r}'
print(f'Exact title selector accepts {title!r}')
