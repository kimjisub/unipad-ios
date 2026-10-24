#!/bin/zsh
# Runs UI tests that need a real hardware key press on an iOS simulator.
#
# XCTest's typeKey never delivers Escape or VoiceOver's keyboard commands to
# an app on the iOS simulator, so tests such as MidiHelpHardwareKeyTests write
# a request file into HOST_KEYS_DIR; this script performs it through the
# simulator's HID input with AXe and answers with a done file. A request holds
# `axe batch` steps, one per line (e.g. "key 41" presses Escape).
#
# AXe reporting a press as performed does not prove the app received it, so
# the script also builds ci/key-arrival-probe.m into HOST_KEYS_DIR; tests load
# it into the app to see which presses actually arrived.
#
#   ci/host-keys.sh <simulator-udid> <derived-data> <xcodebuild test args...>
#   e.g. ci/host-keys.sh "$UDID" "$DD" test-without-building -scheme unipad \
#          -only-testing:unipadUITests/MidiHelpHardwareKeyTests
#
# AXe is used from PATH, else the pinned release is fetched once into
# ~/Library/Caches/unipad-axe and checked against its SHA-256.
set -eu
setopt null_glob

udid=$1 derived=$2
shift 2

axe_version=1.8.0
axe_sha256=7b76340b72e90d0f211bc7c4636f15009076eff07acef2f2b632b175debd8834
axe=$(command -v axe || true)
if [[ -z $axe ]]; then
  cache=$HOME/Library/Caches/unipad-axe/$axe_version
  axe=$cache/axe
  if [[ ! -x $axe ]]; then
    mkdir -p $cache
    archive=$cache/AXe-macOS-v$axe_version-universal.tar.gz
    curl -fsSL -o $archive \
      https://github.com/cameroncooke/AXe/releases/download/v$axe_version/AXe-macOS-v$axe_version-universal.tar.gz
    echo "$axe_sha256  $archive" | shasum -a 256 -c - >/dev/null
    tar -xzf $archive -C $cache
  fi
fi

# The key folder is named after this script's pid so the watcher can remove it
# even when the script is killed without running its EXIT trap; $$ stays this
# script's pid inside the subshell. The watcher starts before the folder exists
# so a kill at any point, mktemp included, leaves no folder behind. It keeps
# none of the caller's output open: a caller that reaps this script only after
# its output closes would otherwise wait on it forever.
temp=${UNIPAD_TEST_TMPDIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}
{
  while kill -0 $$ 2>/dev/null; do sleep 0.2; done
  rm -rf $temp/unipad-host-keys.$$.*
} </dev/null >/dev/null 2>&1 &
watcher=$!
keys=$(mktemp -d "$temp/unipad-host-keys.$$.XXXXXX")
responder=
trap 'kill $watcher $responder 2>/dev/null; rm -rf $keys' EXIT

deliver() {
  local state
  # Xcode 27 keeps legacy keyboard input disconnected after dtuhidd exits idle.
  # AXe selects DTUHID only while that process is running. Wake the existing
  # service on this device before selection; never change its activation state
  # or replay a key that might already have been delivered.
  state=$(xcrun simctl spawn $udid notifyutil -g com.apple.coredevice.dtuhidd.active) || return
  print "$state"
  case $state in
    'com.apple.coredevice.dtuhidd.active 1')
      xcrun simctl spawn $udid launchctl kickstart -p user/$UID/com.apple.coredevice.dtuhidd || return
      ;;
    'com.apple.coredevice.dtuhidd.active 0') ;;
    *) print -u2 "Unrecognized simulator input state: $state"; return 1 ;;
  esac
  $axe batch --udid $udid --file $keys/batch --verbose
}

# The responder ends with this script even when the script is killed without
# running its EXIT trap.
{
  while kill -0 $$ 2>/dev/null; do
    for request in $keys/request-*; do
      id=${request:t}; id=${id#request-}
      steps=$(<$request)
      print "$(date +%T) host request $id: ${steps//$'\n'/; }"
      # Each batch opens a new HID session whose keyboard the simulator takes
      # up to a few hundred milliseconds to register. Keys from a session that
      # closes before that are dropped without an error (AXe still reports
      # them performed), so the session is held open after the steps.
      { print -r -- $steps; print "sleep 1"; } >$keys/batch
      if deliver >$keys/output-$id 2>&1; then
        print successful >$keys/response-$id
      else
        print failed >$keys/response-$id
      fi
      cat $keys/output-$id
      print "$(date +%T) host response $id: $(<$keys/response-$id)"
      rm -f $request
      mv $keys/response-$id $keys/done-$id
    done
    sleep 0.2
  done
} &
responder=$!

xcrun --sdk iphonesimulator clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 \
  -mios-simulator-version-min=17.0 -framework UIKit \
  -o $keys/key-arrival-probe.dylib ${0:A:h}/key-arrival-probe.m

result=0
TEST_RUNNER_HOST_KEYS_DIR=$keys xcodebuild "$@" \
  -destination "id=$udid" -derivedDataPath $derived -parallel-testing-enabled NO -collect-test-diagnostics never || result=$?
exit $result
