#!/bin/bash
# Builds the two download files attached to every GitHub release (run on a Mac):
#   dist/CleanIT-Windows.zip  - the Windows app files of that tag only ($script:AppFiles in its CleanIT.Core.ps1)
#   dist/CleanIT-Mac.zip      - CleanIT.app from the current checkout, universal (Intel + Apple silicon)
# The Windows in-app updater does not use these - it downloads the tag's source zip - so they never affect it.
# Usage:   tools/release-assets.sh v2.7.2
# Upload:  gh release upload v2.7.2 dist/CleanIT-Windows.zip dist/CleanIT-Mac.zip --clobber
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${1:?usage: tools/release-assets.sh vX.Y.Z}
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "No tag $TAG (git fetch --tags?)"; exit 1; }
# the file list, exactly as the updater sees it in that version: 'a.ps1', 'web\x.js', ... -> a.ps1 web/x.js
FILES=$(git show "$TAG:CleanIT.Core.ps1" | tr -d '\r' | sed -n '/^\$script:AppFiles = @(/,/)/p' \
        | grep -o "'[^']*'" | tr -d "'" | tr '\\' '/')
[ -n "$FILES" ] || { echo "Could not read \$script:AppFiles from $TAG"; exit 1; }
rm -rf dist && mkdir dist
git archive --format=zip --prefix=CleanIT/ -o dist/CleanIT-Windows.zip "$TAG" $FILES
mac/build.sh --zip
cp mac/build/CleanIT-Mac.zip dist/
ls -la dist
