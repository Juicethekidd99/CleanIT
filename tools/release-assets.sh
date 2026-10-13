#!/bin/bash
# Builds the two download files attached to every GitHub release (run on a Mac):
#   dist/CleanIT-Windows.zip  - the Windows app files only (same list as $script:AppFiles in CleanIT.Core.ps1)
#   dist/CleanIT-Mac.zip      - CleanIT.app, universal (Intel + Apple silicon)
# The Windows in-app updater does not use these - it downloads the tag's source zip - so they never affect it.
# Upload:  gh release upload vX.Y.Z dist/CleanIT-Windows.zip dist/CleanIT-Mac.zip --clobber
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist && mkdir dist
git archive --format=zip --prefix=CleanIT/ -o dist/CleanIT-Windows.zip HEAD \
  CleanIT.ps1 CleanIT.Core.ps1 CleanIT.Server.ps1 CleanIT.vbs Run-CleanIT.bat web/index.html web/app.css web/app.js LICENSE README.md
mac/build.sh --zip
cp mac/build/CleanIT-Mac.zip dist/
ls -la dist
