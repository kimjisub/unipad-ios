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

keys=$(mktemp -d "${TMPDIR:-/tmp}/unipad-host-keys.XXXXXX")
log=$keys/presses.log
responder=
trap '[[ -n $responder ]] && kill $responder 2>/dev/null; rm -rf $keys' EXIT

xcrun --sdk iphonesimulator clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 \
  -mios-simulator-version-min=17.0 -framework UIKit \
  -o $keys/key-arrival-probe.dylib ${0:A:h}/key-arrival-probe.m

{
  while true; do
    for request in $keys/request-*; do
      id=${request:t}; id=${id#request-}
      steps=$(<$request)
      # Each batch opens a new HID session whose keyboard the simulator takes
      # up to a few hundred milliseconds to register. Keys from a session that
      # closes before that are dropped without an error (AXe still reports
      # them performed), so the session is held open after the steps.
      { print -r -- $steps; print "sleep 1"; } >$keys/batch
      if $axe batch --udid $udid --file $keys/batch >/dev/null; then
        print "$(date +%T) performed: ${steps//$'\n'/; }" >>$log
      else
        print "$(date +%T) FAILED: ${steps//$'\n'/; }" >>$log
      fi
      rm -f $request
      touch $keys/done-$id
    done
    sleep 0.2
  done
} &
responder=$!

result=0
TEST_RUNNER_HOST_KEYS_DIR=$keys xcodebuild "$@" \
  -destination "id=$udid" -derivedDataPath $derived -parallel-testing-enabled NO -collect-test-diagnostics never || result=$?
[[ -f $log ]] && cat $log
exit $result
