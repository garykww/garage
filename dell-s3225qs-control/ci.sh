#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Swift is included on garage's GitHub-hosted Ubuntu runner. Fail explicitly if
# the toolchain is missing rather than reporting an untested app as successful.
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift 5.9 or newer is required for protocol tests." >&2
  exit 1
fi

swift test

if [[ "$(uname -s)" == "Darwin" ]]; then
  zsh build.sh
  codesign --verify --deep --strict "dist/Dell S3225QS Control.app"
  plutil -lint "dist/Dell S3225QS Control.app/Contents/Info.plist"
else
  echo "Protocol tests passed. Native app build and HDMI hardware checks require macOS."
fi
