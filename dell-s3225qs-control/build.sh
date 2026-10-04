#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="dist/Dell S3225QS Control.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/DellS3225QSControl" "$app/Contents/MacOS/DellS3225QSControl"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built: $PWD/$app"
