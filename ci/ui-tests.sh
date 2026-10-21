#!/bin/zsh
# Runs the whole unipadUITests target on one iOS simulator and reports a single
# result line. Skipped tests count as failures: a check whose fixture or
# hardware bridge is missing has not verified anything.
#
#   ci/ui-tests.sh <simulator-udid> [-only-testing:unipadUITests/<Class> ...]
#
# Without test selections every UI test runs. Pass selections to split a long
# run into parts; together the parts must name every test class.
# Results go to $UNIPAD_UI_TEST_OUTPUT (default build/ui-tests): ui-tests.log,
# UITests.xcresult and summary.json. The last line printed is
#   UI tests: <passed> passed, <failed> failed, <skipped> skipped; <total> total; exit <code>
set -u

if (( $# < 1 )); then
  print -u2 "usage: ci/ui-tests.sh <simulator-udid> [-only-testing:unipadUITests/<Class> ...]"
  exit 64
fi
udid=$1
shift
selection=("$@")
(( ${#selection} )) || selection=(-only-testing:unipadUITests)
# Checks this script cannot set up. They are left out by name, not skipped, so any
# skip that remains still fails the run. Run them as their notes say.
not_run=(
  # Needs the virtual MIDI device: run ci/virtual_launchpad_roundtrip.py.
  -skip-testing:unipadUITests/VirtualLaunchpadRoundTripUITests
  # Needs a real sample pack installed and named in UNIPAD_LED_TIMING_VISUAL_PACK.
  -skip-testing:unipadUITests/LedAutoplayUITests
  # Downloads from the real store over the network; this script answers from fixtures.
  -skip-testing:unipadUITests/StoreDownloadTests/testDownloadingAStorePackInstallsIt
  # Pointer input exists only on iPad; this script runs on an iPhone.
  -skip-testing:unipadUITests/PlayInputEdgeUITests/testPointerClicksDragsAndChangesChain
)

cd ${0:A:h:h}
output=${UNIPAD_UI_TEST_OUTPUT:-build/ui-tests}
mkdir -p $output
output=${output:A}
rm -rf $output/UITests.xcresult $output/summary.json

# Each test launch gets its own library and generated packs (see ReleaseTestSupport).
# Clear what earlier runs left on this simulator: only the test-owned folders, after
# unlocking a deletion fixture a crashed test may have left immutable.
if container=$(xcrun simctl get_app_container $udid kim.jisub.unipad data 2>/dev/null) \
    && [[ -d $container/Documents ]]; then
  for leftover in $container/Documents/ReleaseTests $container/Documents/00-ReleaseTestImports; do
    [[ -e $leftover ]] || continue
    chflags -R nouchg $leftover && rm -rf $leftover
  done
fi
export TEST_RUNNER_UNIPAD_RELEASE_SUITE=1
ci/host-keys.sh $udid $output/DerivedData test \
  -project unipad.xcodeproj -scheme unipad -configuration Debug \
  -onlyUsePackageVersionsFromResolvedFile \
  $selection $not_run \
  -resultBundlePath $output/UITests.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  UNIPAD_WARNINGS_AS_ERRORS=YES >$output/ui-tests.log 2>&1
xcodebuild_exit=$?

if xcrun xcresulttool get test-results summary --path $output/UITests.xcresult --compact \
    >$output/summary.json 2>>$output/ui-tests.log \
    && counts=$(python3 ci/check_ui_results.py $output/summary.json 2>/dev/null); then
  code=0
else
  counts=$(python3 ci/check_ui_results.py $output/summary.json 2>/dev/null | head -1)
  [[ -n $counts ]] || counts="UI tests: no complete result (see $output/ui-tests.log)"
  code=1
fi
(( xcodebuild_exit == 0 )) || code=$xcodebuild_exit
print "$counts; exit $code"
exit $code
