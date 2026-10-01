#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
app_path="$project_root/dist/Codex Quota.app"

cd "$project_root"
swift build -c release
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp App/Info.plist "$app_path/Contents/Info.plist"
cp .build/release/CodexQuota "$app_path/Contents/MacOS/CodexQuota"
codesign --force --sign - "$app_path"
echo "$app_path"
