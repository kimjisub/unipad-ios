#!/bin/zsh
# Runs a virtual Launchpad MK2 in a booted iOS Simulator for the LED timing tests' MIDI mode:
#
#   ci/virtual-launchpad.sh <simulator-udid> <seconds> <arrivals-file>
#
# Builds ci/virtual-launchpad.c for the simulator, then runs it there in the foreground for <seconds>;
# start it in the background before the tests. The app connects to it as to a USB Launchpad MK2, and
# every message the app sends is written to <arrivals-file> with its arrival time. The tests read that
# file when started with TEST_RUNNER_UNIPAD_LED_TIMING_MIDI=<arrivals-file>.
set -euo pipefail

if (( $# != 3 )); then
  print -u2 "usage: $0 <simulator-udid> <seconds> <arrivals-file>"
  exit 2
fi
udid=$1
seconds=$2
arrivals=${3:A}

build=$(mktemp -d "${TMPDIR:-/tmp}/virtual-launchpad.XXXXXX")
trap 'rm -rf $build' EXIT
cat > $build/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.unipad.tests.virtual-launchpad</string>
<key>CFBundleName</key><string>virtual-launchpad</string>
<key>UIBackgroundModes</key><array><string>audio</string></array>
</dict></plist>
PLIST
xcrun --sdk iphonesimulator clang -arch arm64 -arch x86_64 -mios-simulator-version-min=17.0 -O2 \
  -framework CoreMIDI -framework CoreFoundation \
  -Wl,-sectcreate,__TEXT,__info_plist,$build/Info.plist \
  -o $build/virtual-launchpad ${0:A:h}/virtual-launchpad.c
codesign -s - -f $build/virtual-launchpad >/dev/null
xcrun simctl spawn $udid $build/virtual-launchpad "Launchpad MK2" $seconds $arrivals
