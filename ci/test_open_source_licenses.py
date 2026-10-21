"""Check that the open source notice check catches every way the list can drift."""
import json
import os
from pathlib import Path
import tempfile
import unittest

import open_source_licenses as notices


class OpenSourceLicensesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(dir=os.environ.get('PAPERCLIP_RUN_SCRATCH_DIR'))
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.repository = self.root / 'repository'
        self.source_packages = self.root / 'SourcePackages'
        self.derived_data = self.root / 'DerivedData'
        self.notices = self.repository / 'notices'
        self.notices.mkdir(parents=True)

        self.write(self.source_packages / 'checkouts/remote-kit/LICENSE', 'Remote license\n')
        self.write(self.source_packages / 'checkouts/remote-kit/third_party/LICENSE', 'Bundled part\n')
        self.write(self.repository / 'Vendor/Local/COPYING', 'Local license\n')
        self.write(self.repository / 'Vendor/Local/vendor.sh', 'LOCAL_VERSION=2.0\n')
        self.pins = {'remote-kit': {
            'identity': 'remote-kit',
            'location': 'https://github.com/example/remote-kit.git',
            'state': {'version': '1.2.3'},
        }}
        self.manifest = {'components': [
            {
                'name': 'Remote Kit', 'version': '1.2.3', 'file': 'license-remote.txt', 'package': 'RemoteKit',
                'source': {'pin': 'remote-kit', 'files': [
                    {'path': 'LICENSE'},
                    {'path': 'third_party/LICENSE', 'heading': 'Bundled part'},
                ]},
            },
            {
                'name': 'Local', 'version': '2.0', 'file': 'license-local.txt', 'package': 'Local',
                'source': {
                    'path': 'Vendor/Local',
                    'version': {'file': 'vendor.sh', 'pattern': r'LOCAL_VERSION=(\S+)'},
                    'files': [{'path': 'COPYING'}],
                },
            },
        ]}
        self.build('RemoteKit', 'Local', notices.PROJECT_NAME)
        notices.write(self.manifest, self.pins, self.source_packages, self.repository, self.notices)

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def build(self, *packages, configuration='Release-iphonesimulator'):
        for package in packages:
            (self.derived_data / f'Build/Intermediates.noindex/{package}.build/{configuration}').mkdir(parents=True)

    def problems(self):
        built = notices.built_packages(self.derived_data, 'Release-iphonesimulator')
        return notices.problems(self.manifest, self.pins, self.source_packages, self.repository,
                                self.notices, built)

    def test_list_that_matches_the_build_passes(self):
        self.assertEqual(self.problems(), [])

    def test_written_text_joins_every_source_file(self):
        self.assertEqual((self.notices / 'license-remote.txt').read_text(),
                         'Remote license' + notices.SEPARATOR + 'Bundled part\n\nBundled part\n')

    def test_package_built_without_an_entry_fails(self):
        self.build('NewKit')
        self.assertEqual(self.problems(),
                         ['NewKit is built into the app but has no entry in OpenSourceLicenses.json'])

    def test_listed_package_that_is_no_longer_built_fails(self):
        self.manifest['components'][0]['package'] = 'RenamedKit'
        self.assertIn('RenamedKit is listed in OpenSourceLicenses.json but the app does not build it',
                      self.problems())

    def test_package_built_only_in_another_configuration_is_not_counted(self):
        self.build('DebugOnlyKit', configuration='Debug-iphonesimulator')
        self.assertEqual(self.problems(), [])

    def test_no_build_at_all_fails(self):
        problems = notices.problems(self.manifest, self.pins, self.source_packages, self.repository,
                                    self.notices, set())
        self.assertIn('the build compiled no Swift packages; is the derived data path right?', problems)

    def test_resolved_version_change_fails(self):
        self.pins['remote-kit']['state']['version'] = '1.3.0'
        self.assertEqual(self.problems(), ['Remote Kit: listed as 1.2.3, but the app uses 1.3.0'])

    def test_vendored_version_change_fails(self):
        self.write(self.repository / 'Vendor/Local/vendor.sh', 'LOCAL_VERSION=2.1\n')
        self.assertEqual(self.problems(), ['Local: listed as 2.0, but the app uses 2.1'])

    def test_pin_missing_from_package_resolved_fails(self):
        del self.pins['remote-kit']
        self.assertIn('Remote Kit: remote-kit is not in Package.resolved', self.problems())

    def test_changed_license_source_fails(self):
        self.write(self.repository / 'Vendor/Local/COPYING', 'Local license, new year\n')
        self.assertEqual(self.problems(),
                         ['Local: license-local.txt differs from its source; run `open_source_licenses.py write`'])

    def test_missing_bundled_text_fails(self):
        (self.notices / 'license-local.txt').unlink()
        self.assertEqual(self.problems(),
                         ['Local: license-local.txt is missing; run `open_source_licenses.py write`'])


class RepositoryManifestTests(unittest.TestCase):
    """The committed list itself, without a build."""

    def setUp(self):
        self.components = notices.load_json(notices.MANIFEST)['components']

    def test_every_listed_text_is_committed(self):
        for component in self.components:
            with self.subTest(component['name']):
                self.assertTrue((notices.NOTICES / component['file']).is_file())

    def test_every_pin_is_resolved_at_the_listed_version(self):
        pins = notices.resolved_pins(notices.RESOLVED)
        for component in self.components:
            if 'pin' in component['source']:
                with self.subTest(component['name']):
                    self.assertEqual(pins[component['source']['pin']]['state']['version'], component['version'])

    def test_vendored_texts_match_their_sources(self):
        for component in self.components:
            if 'path' in component['source']:
                with self.subTest(component['name']):
                    root = notices.REPOSITORY / component['source']['path']
                    self.assertEqual(notices.expected_version(component, {}, root), component['version'])
                    self.assertEqual((notices.NOTICES / component['file']).read_text(encoding='utf-8'),
                                     notices.license_text(component, root))

    def test_every_entry_has_what_the_app_shows(self):
        for component in self.components:
            with self.subTest(component.get('name')):
                for key in ('name', 'version', 'license', 'url', 'file'):
                    self.assertTrue(component.get(key), key)


if __name__ == '__main__':
    unittest.main()
