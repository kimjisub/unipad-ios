"""Offline regression tests; live Apple requests require explicit opt-in."""
from contextlib import redirect_stdout
from http.client import IncompleteRead
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

import app_store_link as store

URL = 'https://apps.apple.com/app/id6760479102'
FINAL = 'https://apps.apple.com/us/app/unipad/id6760479102'
LOOKUP = {'resultCount': 1, 'results': [{'trackId': 6760479102, 'trackName': 'UniPad'}]}


class Response(io.BytesIO):
    def __init__(self, url, body=b'', status=200):
        super().__init__(body)
        self.url, self.status = url, status

    def geturl(self):
        return self.url


class AppStoreLinkTests(unittest.TestCase):
    def check(self, page=None, lookup=None, expected=store.EXPECTED_ID):
        if page is None:
            page = Response(FINAL)
        if lookup is None:
            lookup = Response('https://itunes.apple.com/lookup', json.dumps(LOOKUP).encode())
        responses = [page, lookup]
        with patch('app_store_link.urlopen', side_effect=responses) as request:
            result = store.check_url(URL, expected)
        return result, request

    def test_success_records_redirect_and_identity(self):
        result, request = self.check()
        self.assertEqual(result['verdict'], 'ok')
        self.assertEqual(result['original_url'], URL)
        self.assertEqual(result['final_url'], FINAL)
        self.assertEqual(result['response_status'], 200)
        self.assertEqual(result['track_id'], 6760479102)
        self.assertEqual(result['track_name'], 'UniPad')
        self.assertEqual(request.call_args_list[1].args[0].full_url,
                         'https://itunes.apple.com/lookup?id=6760479102')
        self.assertIn('시뮬레이터 열기 실패는 주소 오류가 아님', result['scope_note'])
        self.assertTrue(result['checked_at'].endswith('Z'))

    def test_http_status_categories_on_both_requests(self):
        for code, verdict in [(400, 'link_error'), (403, 'link_error'),
                              (404, 'link_error'), (429, 'network_unavailable'),
                              (500, 'network_unavailable'), (503, 'network_unavailable')]:
            for lookup in (False, True):
                with self.subTest(code=code, lookup=lookup):
                    failure = HTTPError(FINAL, code, 'fake', {}, None)
                    result, _ = self.check(**{'lookup' if lookup else 'page': failure})
                    self.assertEqual(result['verdict'], verdict)
                    self.assertEqual(result['lookup_status' if lookup else 'response_status'], code)

    def test_network_failures_on_both_requests(self):
        for failure in (TimeoutError('timeout'), URLError(socket.gaierror('DNS failed')),
                        URLError(ConnectionRefusedError('refused')), IncompleteRead(b'partial')):
            for lookup in (False, True):
                with self.subTest(failure=failure, lookup=lookup):
                    result, _ = self.check(**{'lookup' if lookup else 'page': failure})
                    self.assertEqual(result['verdict'], 'network_unavailable')

    def test_lookup_identity_errors(self):
        for payload in ({'resultCount': 0, 'results': []},
                        {'resultCount': 1, 'results': [{'trackId': 1, 'trackName': 'UniPad'}]},
                        {'resultCount': 1, 'results': [{'trackId': 6760479102, 'trackName': 'Other'}]}):
            with self.subTest(payload=payload):
                result, _ = self.check(lookup=Response(FINAL, json.dumps(payload).encode()))
                self.assertEqual(result['verdict'], 'link_error')

    def test_invalid_destination(self):
        for final in ('https://apps.apple.com/', 'https://example.com/app/id6760479102',
                      'https://apps.apple.com/app/id1', 'http://apps.apple.com/app/id6760479102',
                      'https://apps.apple.com/app/id6760479102/other'):
            with self.subTest(final=final):
                result, _ = self.check(page=Response(final))
                self.assertEqual(result['verdict'], 'link_error')

    def test_expected_id_mismatch(self):
        result, request = self.check(expected='1')
        self.assertEqual(result['verdict'], 'link_error')
        request.assert_not_called()

    def test_invalid_lookup_response_is_inconclusive(self):
        result, _ = self.check(lookup=Response(FINAL, b'not JSON'))
        self.assertEqual(result['verdict'], 'network_unavailable')

    def test_real_source_extraction(self):
        self.assertEqual(store.read_source(store.DEFAULT_SOURCE), URL)
        self.assertEqual(store.app_id(URL), '6760479102')

    def test_missing_source_or_declaration_writes_error_json(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('PAPERCLIP_RUN_SCRATCH_DIR')) as folder:
            source, output = Path(folder) / 'MainView.swift', Path(folder) / 'result.json'
            for contents in (None, 'struct MainView {}', 'static let appStoreURL = URL(string: "bad")!'):
                if contents is not None:
                    source.write_text(contents)
                with redirect_stdout(io.StringIO()), patch('app_store_link.urlopen') as request:
                    self.assertEqual(store.main(['--source', str(source), '--out', str(output)]), 1)
                request.assert_not_called()
                self.assertEqual(json.loads(output.read_text())['verdict'], 'link_error')

    def test_simulator_failure_is_recorded_without_changing_verdict(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('PAPERCLIP_RUN_SCRATCH_DIR')) as folder:
            output = Path(folder) / 'result.json'
            with redirect_stdout(io.StringIO()), patch('app_store_link.urlopen', side_effect=[Response(FINAL), Response(
                    FINAL, json.dumps(LOOKUP).encode())]), patch('app_store_link.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 1, '', 'no App Store')) as run:
                self.assertEqual(store.main(['--simulator', 'fake-udid', '--out', str(output)]), 0)
            result = json.loads(output.read_text())
            self.assertEqual(result['verdict'], 'ok')
            self.assertEqual(result['simulator_open']['returncode'], 1)
            self.assertEqual(run.call_args.args[0], ['xcrun', 'simctl', 'openurl', 'fake-udid', URL])

    def test_cli_network_failure_writes_json_and_returns_two(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('PAPERCLIP_RUN_SCRATCH_DIR')) as folder:
            output = Path(folder) / 'result.json'
            with redirect_stdout(io.StringIO()), patch('app_store_link.urlopen',
                                                       side_effect=TimeoutError('offline')):
                self.assertEqual(store.main(['--out', str(output)]), 2)
            self.assertEqual(json.loads(output.read_text())['verdict'], 'network_unavailable')

    def test_simulator_tool_unavailable_is_diagnostic_only(self):
        with patch('app_store_link.subprocess.run', side_effect=FileNotFoundError('xcrun')):
            self.assertIsNone(store.open_simulator('fake-udid', URL)['returncode'])


@unittest.skipUnless(os.environ.get('UNIPAD_LIVE_STORE_CHECK') == '1',
                     'Set UNIPAD_LIVE_STORE_CHECK=1 for live Apple requests')
class LiveAppStoreLinkTests(unittest.TestCase):
    def test_current_app(self):
        result = store.check_url(store.read_source(store.DEFAULT_SOURCE))
        self.assertEqual(result['verdict'], 'ok', result)

    def test_nonexistent_app(self):
        result = store.check_url('https://apps.apple.com/app/id1', expected_id='1')
        self.assertEqual(result['verdict'], 'link_error', result)


if __name__ == '__main__':
    unittest.main()
