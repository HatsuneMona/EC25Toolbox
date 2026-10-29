#!/bin/zsh
# Run the upstream and recovered audio topology cases with a small XCTest shim.
# CLT lacks XCTest; this runner does not replace the full suite on an Xcode host.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/.build/local-audio-tests"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SC="$(xcrun --find swiftc)"
TARGET="${EC25_BUILD_TARGET:-$(uname -m)-apple-macos26.0}"
mkdir -p "$OUT/modcache"
TEST="$ROOT/Tests/EC25ToolboxTests/ModuleAudioTopologyTests.swift"
python3 - "$TEST" "$OUT/main.swift" <<'PYCODE'
import pathlib,re,sys
names=re.findall(r'func (test\w+)\(\)',pathlib.Path(sys.argv[1]).read_text())
assert names, 'No audio topology tests discovered'
lines=['import Foundation','import XCTest','@testable import EC25Toolbox','let t = ModuleAudioTopologyTests()']
for name in names: lines += ['print("RUN '+name+'")','t.'+name+'()']
lines += ['print("tests: '+str(len(names))+', assertions: \(xctShimAssertions), failures: \(xctShimFailures)")','exit(xctShimFailures == 0 ? 0 : 1)']
pathlib.Path(sys.argv[2]).write_text('\n'.join(lines)+'\n')
PYCODE
"$SC" -parse-as-library -swift-version 6 -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$OUT/modcache" -module-name XCTest -emit-module \
  -emit-module-path "$OUT/XCTest.swiftmodule" -c "$ROOT/scripts/local-xctest-shim.swift" -o "$OUT/XCTest.o"
"$SC" -wmo -parse-as-library -enable-testing -swift-version 6 -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$OUT/modcache" -module-name EC25Toolbox -emit-module \
  -emit-module-path "$OUT/EC25Toolbox.swiftmodule" -c \
  "$ROOT/Sources/EC25Toolbox/Features/CallAudio/AudioDeviceModels.swift" \
  "$ROOT/Sources/EC25Toolbox/Features/CallAudio/ModuleAudioTopology.swift" \
  "$ROOT/scripts/local-audio-stubs.swift" -o "$OUT/EC25Toolbox.o"
"$SC" -swift-version 6 -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/modcache" \
  -I "$OUT" "$TEST" "$OUT/main.swift" "$OUT/XCTest.o" "$OUT/EC25Toolbox.o" -o "$OUT/audio-tests"
"$OUT/audio-tests"
