#!/bin/zsh
# Runs unipadTests/PlayUsageRecordTests/MidiInputPathTests against devices published in the simulator's
# own MIDI server, so their messages reach the app through CoreMIDI as a USB device's do:
#
#   ci/midi-input-tests.sh <simulator-udid> <derived-data> <result-folder>
#
# Builds ci/virtual-midi-device.c for the simulator, runs it there for the length of the tests, and
# runs the tests with `test-without-building` from <derived-data> (build-for-testing first). The tests
# see the tool through TEST_RUNNER_UNIPAD_VIRTUAL_MIDI_DIR; without it they run the same cases on
# MidiManager's parser and driver path alone, as CI does. Results: <result-folder>/MidiInput.xcresult,
# midi-input-tests.log and the tool's commands, acks and arrivals.
#
# A virtual endpoint has no entities, so MidiManager connects it as port 0; the tests send other ports
# in the Universal MIDI Packet group. Hardware port order is not exercised.
set -euo pipefail

if (( $# != 3 )); then
  print -u2 "usage: $0 <simulator-udid> <derived-data> <result-folder>"
  exit 2
fi
udid=$1
derived=${2:A}
results=${3:A}
mkdir -p $results
device=$results/device
rm -rf $device $results/MidiInput.xcresult
mkdir -p $device
: > $device/commands

build=$(mktemp -d "$results/virtual-midi-device.XXXXXX")
tool=
cleanup() {
  # simctl spawn hands the tool to the simulator's launchd; stop the tool itself by the pid it printed.
  local pid=$(sed -n 's/^ready: pid=\([0-9]*\).*/\1/p' $results/virtual-midi-device.log 2>/dev/null)
  [[ -n $pid ]] && kill $pid 2>/dev/null || true
  [[ -n $tool ]] && kill $tool 2>/dev/null || true
  rm -rf $build
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > $build/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.unipad.tests.virtual-midi-device</string>
<key>CFBundleName</key><string>virtual-midi-device</string>
<key>UIBackgroundModes</key><array><string>audio</string></array>
</dict></plist>
PLIST
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -O2 \
  -framework CoreMIDI -framework CoreFoundation \
  -Wl,-sectcreate,__TEXT,__info_plist,$build/Info.plist \
  -o $build/virtual-midi-device ${0:A:h}/virtual-midi-device.c
codesign -s - -f $build/virtual-midi-device >/dev/null

xcrun simctl spawn $udid $build/virtual-midi-device 300 $device > $results/virtual-midi-device.log 2>&1 &
tool=$!
for _ in {1..100}; do
  grep -q '^ready:' $results/virtual-midi-device.log 2>/dev/null && break
  sleep 0.1
done
grep -q '^ready:' $results/virtual-midi-device.log || { cat $results/virtual-midi-device.log >&2; exit 1; }

cd ${0:A:h:h}
set +e
TEST_RUNNER_UNIPAD_VIRTUAL_MIDI_DIR=$device xcodebuild test-without-building \
  -project unipad.xcodeproj -scheme unipad -configuration Debug \
  -destination "id=$udid" -derivedDataPath $derived -parallel-testing-enabled NO \
  -only-testing:unipadTests/PlayUsageRecordTests/MidiInputPathTests \
  -resultBundlePath $results/MidiInput.xcresult > $results/midi-input-tests.log 2>&1
code=$?
set -e
grep -E '^(✔|✘|􁁛)? ?(Test|Suite) .*(passed|failed|skipped)' $results/midi-input-tests.log | tail -40 || true
print "MIDI input tests: exit $code"
exit $code
