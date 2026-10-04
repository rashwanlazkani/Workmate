#!/bin/zsh
set -eu
cd "${0:A:h}/.."
build_root="${TMPDIR%/}/workmate-native-build"
toolchain_bin=$(dirname "$(xcrun --find swiftc)")
testing_plugin="$toolchain_bin/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
plugin_flags=()
if [[ -f "$testing_plugin" ]]; then
  plugin_flags=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test --scratch-path "$build_root" --disable-xctest "${plugin_flags[@]}" "$@"
