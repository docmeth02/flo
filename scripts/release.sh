#!/bin/bash
# Bumps the build number, tests, archives and uploads flo watch to TestFlight,
# then commits the bump and moves the testflight branch. Pushing stays manual.
#
#   scripts/release.sh            release from watchos
#   scripts/release.sh --dry-run  everything up to the upload, then undo the bump
#
# The App Store Connect API key is read from ~/.appstoreconnect/flo-release.env
# (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID), which never enters the repo.

set -euo pipefail

dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

cd "$(dirname "$0")/.."
project=flo.xcodeproj/project.pbxproj
simulator=0B3254A5-34F8-4FC6-8C75-641D7EBA8331

fail() { echo "release: $*" >&2; exit 1; }

git diff --quiet && git diff --cached --quiet || fail "the working tree has changes"
branch=$(git branch --show-current)
$dry_run || [[ "$branch" == watchos ]] || fail "release from watchos, not $branch"

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
[[ $(grep -c "CURRENT_PROJECT_VERSION = $current;" "$project") -eq 4 ]] \
  || fail "expected CURRENT_PROJECT_VERSION = $current four times"

work=$(mktemp -d)
log="$work/xcodebuild.log"
# Every exit before the commit, a failure or a dry run, takes the bump back.
bumped=false
finish() { if $bumped; then git checkout -q -- "$project"; fi; }
trap finish EXIT

sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $build;/" "$project"
bumped=true
echo "release: build $build from $branch at $(git rev-parse --short HEAD)"

echo "release: testing"
xcodebuild test -project flo.xcodeproj -scheme "flo Watch App" \
  -destination "platform=watchOS Simulator,id=$simulator" >"$log" 2>&1 \
  || fail "tests failed, see $log"
xcrun simctl terminate "$simulator" host.docmeth02.flowatch.watchkitapp 2>/dev/null || true

echo "release: archiving"
xcodebuild archive -project flo.xcodeproj -scheme "flo watch" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$work/flowatch.xcarchive" "${auth[@]}" \
  >"$log" 2>&1 || fail "archive failed, see $log"

binary=$(find "$work/flowatch.xcarchive" -type f -path "*flo Watch App.app/flo Watch App" | head -1)
[[ -n "$binary" ]] || fail "no watch binary in the archive"
# Through a file: grep -q ending a pipe early could fail the check open.
strings "$binary" >"$work/strings.txt" || fail "cannot read the release binary"
if grep -q FLO_DEBUG "$work/strings.txt"; then fail "the release binary contains FLO_DEBUG"; fi

if $dry_run; then
  echo "release: dry run done, build $build archived in $work, nothing uploaded"
  exit 0
fi

echo "release: uploading"
xcodebuild -exportArchive -archivePath "$work/flowatch.xcarchive" \
  -exportOptionsPlist scripts/export.plist -exportPath "$work/export" "${auth[@]}" \
  >"$log" 2>&1 || fail "upload failed, see $log"

git commit -q -m "bump build number to $build" -- "$project"
bumped=false
echo "release: build $build uploaded and committed"
git branch -f testflight HEAD || fail "move testflight to $(git rev-parse --short HEAD) by hand"
echo "release: testflight moved to $(git rev-parse --short HEAD); push when ready"
