#!/bin/zsh
# CLT-only runner for the production forwarding models/sender/store/Keychain wrapper.
# Tests inject in-memory credentials and mock HTTP; no real credentials or endpoints are used.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/.build/local-forwarding-core-tests"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SC="$(xcrun --find swiftc)"
TARGET="${EC25_BUILD_TARGET:-$(uname -m)-apple-macos26.0}"
mkdir -p "$OUT/modcache"
python3 - "$ROOT" "$OUT" <<'PY'
import pathlib,re,sys
root,out=map(pathlib.Path,sys.argv[1:])
test=(root/'Tests/EC25ToolboxTests/SMSForwardingCoreTests.swift').read_text()
methods=re.findall(r'func (test\w+)\(\)([^\{]*)\{',test)
assert methods, 'No forwarding core tests discovered'
lines=['import Foundation','import XCTest','@testable import EC25Toolbox','@main struct Runner {','@MainActor static func main() async {','let t = SMSForwardingCoreTests()']
for name,modifiers in methods:
    call=('try ' if 'throws' in modifiers else '')+('await ' if 'async' in modifiers else '')+'t.'+name+'()'
    lines+=['print("RUN '+name+'")']
    if 'throws' in modifiers:
        lines+=['do { '+call+' } catch { XCTAssertTrue(false, "Unexpected error: \\(error)") }']
    else: lines+=[call]
lines+=['print("tests: '+str(len(methods))+', assertions: \\(xctShimAssertions), failures: \\(xctShimFailures)")','exit(xctShimFailures == 0 ? 0 : 1)','}','}']
(out/'Runner.swift').write_text('\n'.join(lines)+'\n')
PY
"$SC" -parse-as-library -swift-version 6 -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/modcache" \
  -module-name XCTest -emit-module -emit-module-path "$OUT/XCTest.swiftmodule" \
  -c "$ROOT/scripts/local-xctest-shim.swift" -o "$OUT/XCTest.o"
SRC="$ROOT/Sources/EC25Toolbox/Features/SMSForwarding"
"$SC" -wmo -parse-as-library -enable-testing -swift-version 6 -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$OUT/modcache" -module-name EC25Toolbox -emit-module \
  -emit-module-path "$OUT/EC25Toolbox.swiftmodule" -c \
  "$SRC/SMSForwardingModels.swift" "$SRC/SMSForwardingSender.swift" \
  "$SRC/SMSForwardingSecrets.swift" "$SRC/SMSForwardingStore.swift" -o "$OUT/EC25Toolbox.o"
"$SC" -parse-as-library -swift-version 6 -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/modcache" -I "$OUT" \
  "$ROOT/Tests/EC25ToolboxTests/SMSForwardingCoreTests.swift" "$OUT/Runner.swift" \
  "$OUT/XCTest.o" "$OUT/EC25Toolbox.o" -o "$OUT/core-tests"
"$OUT/core-tests"
