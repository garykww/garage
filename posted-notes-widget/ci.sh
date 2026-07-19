#!/usr/bin/env bash
set -euo pipefail

# macOS-only app: WidgetKit + SwiftUI. Skip cleanly on non-Mac CI runners.
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not available on this runner — skipping macOS-only app."
  exit 0
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "xcodegen not available and no Homebrew to install it — skipping."
    exit 0
  fi
fi

xcodegen generate
xcodebuild -project PostedNotes.xcodeproj \
  -scheme PostedNotes \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
