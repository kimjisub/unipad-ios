"""Write a fake Firebase plist for CI; never read production configuration."""
import argparse
from pathlib import Path
import plistlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    config = {
        'API_KEY': 'FAKE-CI-API-KEY-NOT-A-CREDENTIAL',
        'GCM_SENDER_ID': '000000000000',
        'BUNDLE_ID': 'kim.jisub.unipad',
        'PROJECT_ID': 'fake-unipad-ci',
        'STORAGE_BUCKET': 'fake-unipad-ci.invalid',
        'GOOGLE_APP_ID': '1:000000000000:ios:0000000000000000',
        'IS_ADS_ENABLED': False,
        'IS_ANALYTICS_ENABLED': False,
        'IS_APPINVITE_ENABLED': False,
        'IS_GCM_ENABLED': False,
        'IS_SIGNIN_ENABLED': False,
    }
    with args.output.open('wb') as file:
        plistlib.dump(config, file)


if __name__ == '__main__':
    main()
