"""Keep the app's open source notices in step with the packages it is built from.

The app shows every component listed in OpenSourceLicenses.json with the license
text bundled next to it. Each entry names where that text comes from: a file in a
resolved Swift package checkout (`pin`, an identity from Package.resolved) or in a
local package (`path`). This script

- `write`: regenerates the bundled license texts from those sources;
- `check`: fails when a package the app build compiled is missing from the list,
  a listed package was not built, a listed version differs from the one resolved
  or vendored, or a bundled text differs from its source.

`check` reads a finished build's derived data, where Xcode keeps one
`<package>.build` folder per Swift package it built for the app.
"""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse

REPOSITORY = Path(__file__).resolve().parent.parent
NOTICES = REPOSITORY / 'unipad/Resources/OpenSourceLicenses'
MANIFEST = NOTICES / 'OpenSourceLicenses.json'
RESOLVED = REPOSITORY / 'unipad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
PROJECT_NAME = 'unipad'
SEPARATOR = '\n\n' + '=' * 80 + '\n\n'


def load_json(path):
    with path.open(encoding='utf-8') as file:
        return json.load(file)


def resolved_pins(resolved_path):
    return {pin['identity']: pin for pin in load_json(resolved_path)['pins']}


def source_root(component, pins, source_packages, repository):
    source = component['source']
    if 'path' in source:
        return repository / source['path']
    pin = pins.get(source['pin'])
    if pin is None:
        return None
    checkout = Path(urlparse(pin['location']).path).name.removesuffix('.git')
    return source_packages / 'checkouts' / checkout


def expected_version(component, pins, root):
    source = component['source']
    if 'pin' in source:
        pin = pins.get(source['pin'])
        return pin and pin['state'].get('version')
    rule = source['version']
    match = re.search(rule['pattern'], (root / rule['file']).read_text(encoding='utf-8'))
    return match and match.group(1)


def license_text(component, root):
    parts = []
    for item in component['source']['files']:
        text = (root / item['path']).read_text(encoding='utf-8').strip('\n')
        if 'heading' in item:
            text = f"{item['heading']}\n\n{text}"
        parts.append(text)
    return SEPARATOR.join(parts) + '\n'


def built_packages(derived_data, configuration):
    intermediates = Path(derived_data) / 'Build/Intermediates.noindex'
    return {
        folder.name.removesuffix('.build')
        for folder in intermediates.glob('*.build')
        if (folder / configuration).is_dir() and folder.name != f'{PROJECT_NAME}.build'
    }


def problems(manifest, pins, source_packages, repository, notices, built):
    found = []
    components = manifest['components']
    listed = {component['package'] for component in components}
    if not built:
        found.append('the build compiled no Swift packages; is the derived data path right?')
    for package in sorted(built - listed):
        found.append(f'{package} is built into the app but has no entry in {MANIFEST.name}')
    for package in sorted(listed - built):
        found.append(f'{package} is listed in {MANIFEST.name} but the app does not build it')

    for component in components:
        name = component['name']
        root = source_root(component, pins, source_packages, repository)
        if root is None:
            found.append(f"{name}: {component['source']['pin']} is not in Package.resolved")
            continue
        version = expected_version(component, pins, root)
        if version != component['version']:
            found.append(f"{name}: listed as {component['version']}, but the app uses {version}")
        bundled = notices / component['file']
        if not bundled.is_file():
            found.append(f"{name}: {component['file']} is missing; run `{Path(__file__).name} write`")
        elif bundled.read_text(encoding='utf-8') != license_text(component, root):
            found.append(f"{name}: {component['file']} differs from its source; "
                         f"run `{Path(__file__).name} write`")
    return found


def write(manifest, pins, source_packages, repository, notices):
    for component in manifest['components']:
        root = source_root(component, pins, source_packages, repository)
        (notices / component['file']).write_text(license_text(component, root), encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=['check', 'write'])
    parser.add_argument('--source-packages', type=Path, required=True,
                        help='the folder passed to xcodebuild -clonedSourcePackagesDirPath')
    parser.add_argument('--derived-data', type=Path,
                        help='the folder passed to xcodebuild -derivedDataPath (check only)')
    parser.add_argument('--configuration', default='Release-iphonesimulator',
                        help='the build configuration folder to read (default: %(default)s)')
    args = parser.parse_args(argv)

    manifest = load_json(MANIFEST)
    pins = resolved_pins(RESOLVED)
    if args.command == 'write':
        write(manifest, pins, args.source_packages, REPOSITORY, NOTICES)
        return 0
    if args.derived_data is None:
        parser.error('check needs --derived-data')

    built = built_packages(args.derived_data, args.configuration)
    found = problems(manifest, pins, args.source_packages, REPOSITORY, NOTICES, built)
    for problem in found:
        print(f'error: {problem}', file=sys.stderr)
    if found:
        return 1
    print(f"{len(manifest['components'])} open source notices match the {len(built)} packages built into the app")
    return 0


if __name__ == '__main__':
    sys.exit(main())
