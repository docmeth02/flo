#!/bin/bash
# Bumps the build number, tests, archives and uploads Ownwave to TestFlight,
# then commits the bump and moves the testflight branch. Pushing stays manual.
#
#   scripts/release.sh            release from main
#   scripts/release.sh --dry-run  everything up to the upload, then undo the bump
#
# The App Store Connect API key is read from ~/.appstoreconnect/flo-release.env
# (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID), which never enters the repo.

set -euo pipefail

dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

cd "$(dirname "$0")/.."
project=Ownwave.xcodeproj/project.pbxproj
simulator=0B3254A5-34F8-4FC6-8C75-641D7EBA8331
# The engine tests compile the shared sources for iOS.
iphone_simulator=FCC76D75-A677-4993-944A-98777D8A0A67

fail() { echo "release: $*" >&2; exit 1; }

git diff --quiet && git diff --cached --quiet || fail "the working tree has changes"
branch=$(git branch --show-current)
$dry_run || [[ "$branch" == main ]] || fail "release from main, not $branch"

env_file="$HOME/.appstoreconnect/flo-release.env"
[[ -f "$env_file" ]] || fail "missing $env_file"
# shellcheck source=/dev/null
source "$env_file"
[[ -f "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] \
  || fail "$env_file must set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$')
build=$((current + 1))
# Every target carries the same build number.
[[ $(grep -c "CURRENT_PROJECT_VERSION = $current;" "$project") \
  -eq $(grep -c "CURRENT_PROJECT_VERSION = " "$project") ]] \
  || fail "expected every CURRENT_PROJECT_VERSION to be $current"

work=$(mktemp -d)
log="$work/xcodebuild.log"
# Every exit before the upload, a failure or a dry run, takes the bump back.
bumped=false
finish() {
  if $bumped; then git checkout -q -- "$project"; fi
  xcrun simctl terminate "$simulator" de.m2-entertainment.ownwave.watchkitapp 2>/dev/null || true
  xcrun simctl shutdown "$iphone_simulator" 2>/dev/null || true
}
trap finish EXIT

sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $build;/" "$project"
bumped=true
echo "release: build $build from $branch at $(git rev-parse --short HEAD)"

echo "release: testing"
xcodebuild test -project Ownwave.xcodeproj -scheme "Ownwave Watch App" \
  -destination "platform=watchOS Simulator,id=$simulator" >"$log" 2>&1 \
  || fail "tests failed, see $log"
xcodebuild test -project Ownwave.xcodeproj -scheme "Ownwave EngineTests" \
  -destination "platform=iOS Simulator,id=$iphone_simulator" >"$log" 2>&1 \
  || fail "engine tests failed, see $log"

echo "release: archiving"
xcodebuild archive -project Ownwave.xcodeproj -scheme "Ownwave" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$work/ownwave.xcarchive" "${auth[@]}" \
  >"$log" 2>&1 || fail "archive failed, see $log"

for path in "Ownwave.app/Ownwave" "OwnwaveWidgets.appex/OwnwaveWidgets" \
  "Ownwave Watch App.app/Ownwave Watch App"; do
  binary=$(find "$work/ownwave.xcarchive" -type f -path "*/$path" | head -1)
  [[ -n "$binary" ]] || fail "no $path in the archive"
  # Through a file: grep -q ending a pipe early could fail the check open.
  strings "$binary" >"$work/strings.txt" || fail "cannot read $path"
  if grep -q FLO_DEBUG "$work/strings.txt"; then fail "$path contains FLO_DEBUG"; fi
done

if $dry_run; then
  echo "release: dry run done, build $build archived in $work, nothing uploaded"
  exit 0
fi

echo "release: uploading"
xcodebuild -exportArchive -archivePath "$work/ownwave.xcarchive" \
  -exportOptionsPlist scripts/export.plist -exportPath "$work/export" "${auth[@]}" \
  >"$log" 2>&1 || fail "upload failed, see $log"
# Build $build is on App Store Connect now; its number must stay taken.
bumped=false

git commit -q -m "bump build number to $build" -- "$project" \
  || fail "build $build uploaded, commit the bump by hand"
echo "release: build $build uploaded and committed"
git branch -f testflight HEAD || fail "move testflight to $(git rev-parse --short HEAD) by hand"
echo "release: testflight moved to $(git rev-parse --short HEAD); push when ready"
