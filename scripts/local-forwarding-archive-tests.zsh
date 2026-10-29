#!/bin/zsh
# Exercise the real SMS assembler and forwarding projection with the CLT runner.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/.build/local-forwarding-archive-tests"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SC="$(xcrun --find swiftc)"
TARGET="${EC25_BUILD_TARGET:-$(uname -m)-apple-macos26.0}"
mkdir -p "$OUT/modcache"
python3 - "$ROOT" "$OUT" <<'PYCODE'
import pathlib,re,sys
root,out=map(pathlib.Path,sys.argv[1:])
# Compile the exact production scope declaration without pulling the entire
# application persistence/UI dependency graph into this focused runner.
s=(root/'Sources/EC25Toolbox/Features/SMS/SMSArchiveStore.swift').read_text()
start=s.index('struct SIMMessageScope:')
end=s.index('\n}\n',start)+3
(out/'Scope.swift').write_text('import Foundation\nimport CryptoKit\n'+s[start:end])
test=(root/'Tests/EC25ToolboxTests/SMSForwardingArchiveSnapshotTests.swift').read_text()
names=re.findall(r'func (test\w+)\(\)',test)
lines=['import Foundation','import XCTest','@testable import EC25Toolbox','let t = SMSForwardingArchiveSnapshotTests()']
for name in names: lines += ['print("RUN '+name+'")','t.'+name+'()']
lines += ['print("tests: '+str(len(names))+', assertions: \(xctShimAssertions), failures: \(xctShimFailures)")','exit(xctShimFailures == 0 ? 0 : 1)']
(out/'main.swift').write_text('\n'.join(lines)+'\n')
PYCODE
"$SC" -parse-as-library -swift-version 6 -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/modcache" \
  -module-name XCTest -emit-module -emit-module-path "$OUT/XCTest.swiftmodule" \
  -c "$ROOT/scripts/local-xctest-shim.swift" -o "$OUT/XCTest.o"
SRC="$ROOT/Sources/EC25Toolbox"
"$SC" -wmo -parse-as-library -enable-testing -swift-version 6 -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$OUT/modcache" -module-name EC25Toolbox -emit-module \
  -emit-module-path "$OUT/EC25Toolbox.swiftmodule" -c \
  "$OUT/Scope.swift" "$SRC/AT/Parsing/TextParsing.swift" "$SRC/AT/Parsing/UCS2Codec.swift" \
  "$SRC/AT/Parsing/SMSParsing.swift" "$SRC/Features/SMS/SMSPDU.swift" \
  "$SRC/Features/SMS/GSM7Bit.swift" "$SRC/Features/SMS/BinarySMSClassifier.swift" \
  "$SRC/Features/SMS/SMSTimeModels.swift" "$SRC/Features/SMS/SMSLogicalModels.swift" \
  "$SRC/Features/SMSForwarding/SMSForwardingModels.swift" \
  "$SRC/Features/SMS/SMSForwardingArchiveSnapshot.swift" -o "$OUT/EC25Toolbox.o"
"$SC" -swift-version 6 -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/modcache" -I "$OUT" \
  "$ROOT/Tests/EC25ToolboxTests/SMSForwardingArchiveSnapshotTests.swift" "$OUT/main.swift" \
  "$OUT/XCTest.o" "$OUT/EC25Toolbox.o" -o "$OUT/archive-tests"
"$OUT/archive-tests"
