"""Fail CI when Xcode reports skipped, failed, empty, or incomplete UI results."""
import argparse
import json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=argparse.FileType('r'))
    args = parser.parse_args()
    with args.summary as file:
        summary = json.load(file)
    keys = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')
    for key in keys:
        count = summary.get(key)
        if type(count) is not int or count < 0:
            raise SystemExit(f'Invalid or missing UI result count: {key}')
    total, passed, failed, skipped = (summary[key] for key in keys)
    print(f'UI tests: {passed} passed, {failed} failed, {skipped} skipped; {total} total')
    if total == 0 or passed != total or failed != 0 or skipped != 0:
        raise SystemExit('Every UI test must run and pass; missing fixtures are failures, not coverage.')


if __name__ == '__main__':
    main()
