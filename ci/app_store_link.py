"""Read-only Apple web destination check, independent of simulator URL handling.

이 판정은 웹 주소 기준이며 시뮬레이터 열기 실패는 주소 오류가 아님.
Exit codes: 0 = ok, 1 = link_error, 2 = network_unavailable.
"""
import argparse
from datetime import datetime, timezone
from http.client import HTTPException
import json
from pathlib import Path
import re
import subprocess
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

EXPECTED_ID = '6760479102'
DEFAULT_SOURCE = Path(__file__).resolve().parents[1] / 'unipad/Views/Main/MainView.swift'
SCOPE_NOTE = '이 판정은 웹 주소 기준이며 시뮬레이터 열기 실패는 주소 오류가 아님'
EXIT_CODES = {'ok': 0, 'link_error': 1, 'network_unavailable': 2}
TIMEOUT = 30


def read_source(source):
    match = re.search(r'^\s*static\s+let\s+appStoreURL\s*=\s*URL\(\s*string:\s*"([^"]+)"',
                      Path(source).read_text(encoding='utf-8'), re.MULTILINE)
    if not match:
        raise ValueError('Could not find the appStoreURL string in MainView.swift')
    return match[1]


def app_id(url):
    """Accept only HTTPS Apple app pages ending in a numeric app ID."""
    try:
        parts = urlsplit(url)
        if parts.scheme != 'https' or parts.netloc != 'apps.apple.com':
            return None
        match = re.fullmatch(r'/(?:[a-z]{2}/)?app/(?:[^/]+/)?id([0-9]+)/?', parts.path)
        return match[1] if match else None
    except ValueError:
        return None


def new_result(url):
    return {'original_url': url, 'final_url': None, 'response_status': None,
            'lookup_status': None, 'track_id': None, 'track_name': None,
            'verdict': 'link_error', 'detail': '', 'scope_note': SCOPE_NOTE,
            'checked_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}


def status_verdict(status):
    if status == 429 or 500 <= status <= 599:
        return 'network_unavailable'
    return 'ok' if status == 200 else 'link_error'


def fetch(url, result, lookup=False):
    """Follow redirects; retain HTTP evidence even for error responses."""
    status_key = 'lookup_status' if lookup else 'response_status'
    try:
        with urlopen(Request(url, headers={'User-Agent': 'UniPad-App-Store-Link-Check/1.0'}),
                     timeout=TIMEOUT) as response:
            result[status_key] = response.status
            if not lookup:
                result['final_url'] = response.geturl()
            verdict = status_verdict(response.status)
            if verdict != 'ok':
                result.update(verdict=verdict, detail=f'HTTP {response.status}: {url}')
                return None
            return response.read() if lookup else b''
    except HTTPError as error:
        result[status_key] = error.code
        if not lookup:
            result['final_url'] = error.geturl()
        result.update(verdict=status_verdict(error.code), detail=f'HTTP {error.code}: {url}')
        error.close()
    except (URLError, OSError, HTTPException) as error:
        result.update(verdict='network_unavailable', detail=str(error))
    return None


def check_url(url, expected_id=EXPECTED_ID):
    result = new_result(url)
    identifier = app_id(url)
    if identifier is None or identifier != str(expected_id):
        result['detail'] = 'Source URL is not the expected Apple app page'
        return result
    if fetch(url, result) is None:
        return result
    if app_id(result['final_url']) != str(expected_id):
        result['detail'] = 'Final URL is not the expected Apple app page'
        return result
    body = fetch(f'https://itunes.apple.com/lookup?id={identifier}', result, lookup=True)
    if body is None:
        return result
    try:
        payload = json.loads(body)
        if not isinstance(payload, dict) or not isinstance(payload.get('results'), list):
            raise ValueError('Invalid Apple lookup response')
        if payload.get('resultCount') == 0 and payload['results'] == []:
            result['detail'] = 'Apple lookup found no app'
            return result
        if payload.get('resultCount') != 1 or len(payload['results']) != 1:
            raise ValueError('Unexpected Apple lookup result count')
        app = payload['results'][0]
        if not isinstance(app, dict):
            raise ValueError('Invalid Apple lookup app record')
        result['track_id'], result['track_name'] = app.get('trackId'), app.get('trackName')
    except (ValueError, UnicodeError) as error:
        result.update(verdict='network_unavailable', detail=str(error))
        return result
    if (result['track_id'] != int(expected_id) or
            not isinstance(result['track_name'], str) or 'UniPad' not in result['track_name']):
        result['detail'] = 'Apple lookup app ID or name does not match UniPad'
        return result
    result.update(verdict='ok', detail='Apple web destination and lookup match UniPad')
    return result


def open_simulator(udid, url):
    """Record optional simulator diagnostics; never feed them into the verdict."""
    try:
        completed = subprocess.run(['xcrun', 'simctl', 'openurl', udid, url],
                                   capture_output=True, text=True, timeout=TIMEOUT)
        return {'udid': udid, 'returncode': completed.returncode,
                'stdout': completed.stdout, 'stderr': completed.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'udid': udid, 'returncode': None, 'error': str(error)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--expected-id', default=EXPECTED_ID, type=lambda value: str(int(value)))
    parser.add_argument('--out', type=Path)
    parser.add_argument('--simulator', metavar='UDID', help='Optional diagnostic only; does not affect verdict')
    args = parser.parse_args(argv)
    try:
        url = read_source(args.source)
    except (OSError, ValueError) as error:
        result = new_result(None)
        result['detail'] = str(error)
    else:
        result = check_url(url, args.expected_id)
        if args.simulator:
            result['simulator_open'] = open_simulator(args.simulator, url)
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.out:
        args.out.write_text(encoded, encoding='utf-8')
    print(encoded, end='')
    return EXIT_CODES[result['verdict']]


if __name__ == '__main__':
    raise SystemExit(main())
