#!/bin/zsh
# Adds or removes a folder named "unipad" under On My iPhone on a simulator, so the
# file picker lists a folder with the app's name that does not hold the UI tests' files.
#
# Every app named UniPad has its own "UniPad" folder there, and shared simulators often
# hold other builds of UniPad installed under their own bundle identifier. The order of
# same-named folders is not fixed; this folder sorts before all of them (lowercase first),
# so a picker step that opens the first folder with the app's name, instead of the one
# holding its files, fails on every run rather than now and then.
#
#   ci/same-name-folder.sh add <simulator-udid>
#   ci/same-name-folder.sh remove <simulator-udid>
#
# Removing deletes the folder only while it holds nothing but the file this script put there.
set -eu

action=$1 udid=$2
groups=$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Shared/AppGroup
storage=
for metadata in $groups/*/.com.apple.mobile_container_manager.metadata.plist(N); do
  if [[ $(plutil -extract MCMMetadataIdentifier raw $metadata 2>/dev/null) == group.com.apple.FileProvider.LocalStorage ]]; then
    storage="${metadata:h}/File Provider Storage"
    break
  fi
done
if [[ -z $storage ]]; then
  # A simulator gets this storage once the Files app has run on it.
  [[ $action == add ]] && print -u2 "No On My iPhone storage on simulator $udid; no same-name folder added."
  exit 0
fi
folder=$storage/unipad
marker=$folder/same-name-folder.txt

case $action in
  add)
    mkdir -p $folder
    print 'Added by ci/same-name-folder.sh for the UI tests; not UniPad data.' >$marker
    ;;
  remove)
    [[ -d $folder ]] || exit 0
    rm -f $marker
    rmdir $folder 2>/dev/null || print -u2 "Left $folder in place: it holds other files."
    ;;
  *)
    print -u2 "usage: ci/same-name-folder.sh add|remove <simulator-udid>"
    exit 64
    ;;
esac
