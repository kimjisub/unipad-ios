"""Fail CI when Xcode reports skipped, failed, empty, or incomplete UI results."""
import argparse
import json


def result_counts(summary):
    keys = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')
    for key in keys:
        count = summary.get(key)
        if type(count) is not int or count < 0:
            raise ValueError(f'Invalid or missing UI result count: {key}')
    return tuple(summary[key] for key in keys)


def check_summary(summary):
    total, passed, failed, skipped = result_counts(summary)
    if total == 0 or passed != total or failed != 0 or skipped != 0:
        raise ValueError('Every UI test must run and pass; missing fixtures are failures, not coverage.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=argparse.FileType('r'))
    args = parser.parse_args()
    with args.summary as file:
        summary = json.load(file)
    try:
        total, passed, failed, skipped = result_counts(summary)
        print(f'UI tests: {passed} passed, {failed} failed, {skipped} skipped; {total} total')
        check_summary(summary)
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
