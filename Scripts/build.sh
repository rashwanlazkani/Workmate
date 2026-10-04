#!/bin/zsh
set -eu
cd "${0:A:h}/.."
build_root="${TMPDIR%/}/workmate-native-build"
swift build --scratch-path "$build_root" -c release
binary_dir=$(swift build --scratch-path "$build_root" -c release --show-bin-path)
app="$build_root/Workmate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Workmate" "$app/Contents/MacOS/Workmate"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/CloudConfig.json "$app/Contents/Resources/CloudConfig.json"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
# A stable Apple-issued identity preserves macOS privacy approvals across updates.
# Never silently fall back to ad-hoc signing: its requirement changes each build.
signing_identity="${WORKMATE_SIGNING_IDENTITY:--}"
codesign --force --deep --sign "$signing_identity" --identifier se.workmate.mac --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# Publish one app bundle without overwriting the executable of a running app.
stage=$(mktemp -d "$PWD/.workmate-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto --norsrc "$app" "$stage/Workmate.app"
if [[ -d Workmate.app ]]; then mv Workmate.app "$stage/previous.app"; fi
if ! mv "$stage/Workmate.app" Workmate.app; then
  if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" Workmate.app; fi
  exit 1
fi
echo "Built $PWD/Workmate.app"
