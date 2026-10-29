#!/bin/zsh
# Direct swiftc build of the EC25Toolbox executable (no SwiftPM).
# This Mac's Command Line Tools ship a PackageDescription interface and dylib
# that disagree, so no Package.swift can be evaluated here.
set -euo pipefail

SRC="${0:A:h:h}"
S="$SRC/.build/local-clt"
OUT="$S/manual"
CLT=/Library/Developer/CommandLineTools
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC=$CLT/usr/bin/swiftc
CLANG=$CLT/usr/bin/clang
TARGET="${EC25_BUILD_TARGET:-$(uname -m)-apple-macos26.0}"
MODCACHE=$S/modcache

rm -rf "$OUT"
mkdir -p "$OUT/cmodule" "$MODCACHE"
export CLANG_MODULE_CACHE_PATH="$MODCACHE"

echo "== C target"
"$CLANG" -c -O2 -target "$TARGET" -isysroot "$SDK" \
    -I "$SRC/Sources/CVoWiFiCrypto/include" \
    "$SRC/Sources/CVoWiFiCrypto/CVoWiFiCrypto.c" -o "$OUT/CVoWiFiCrypto.o"
cat > "$OUT/cmodule/module.modulemap" <<EOF
module CVoWiFiCrypto {
    umbrella header "$SRC/Sources/CVoWiFiCrypto/include/CVoWiFiCrypto.h"
    export *
}
EOF

echo "== protocol modules"
for M in EC25IKEHelperProtocol EC25SystemHelperProtocol; do
    "$SWIFTC" -parse-as-library -O -swift-version 6 -target "$TARGET" -sdk "$SDK" \
        -module-cache-path "$MODCACHE" -module-name "$M" \
        -emit-module -emit-module-path "$OUT/$M.swiftmodule" \
        -c "$SRC/Sources/$M/$M.swift" -o "$OUT/$M.o"
done

echo "== resource bundle accessor"
cat > "$OUT/resource_bundle_accessor.swift" <<'EOF'
import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let name = "EC25Toolbox_EC25Toolbox.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
            .compactMap { $0?.appendingPathComponent(name) }
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        Swift.fatalError("unable to find bundle named EC25Toolbox_EC25Toolbox")
    }()
}
EOF

echo "== main target"
FILES=("${(@f)$(find "$SRC/Sources/EC25Toolbox" -name '*.swift' | sort)}")
echo "swift files: ${#FILES[@]}"
"$SWIFTC" -parse-as-library -O -wmo -swift-version 6 -suppress-warnings \
    -target "$TARGET" -sdk "$SDK" -module-cache-path "$MODCACHE" \
    -module-name EC25Toolbox \
    -I "$OUT" -I "$OUT/cmodule" -Xcc -fmodule-map-file="$OUT/cmodule/module.modulemap" \
    "${FILES[@]}" "$OUT/resource_bundle_accessor.swift" \
    "$OUT/CVoWiFiCrypto.o" "$OUT/EC25IKEHelperProtocol.o" "$OUT/EC25SystemHelperProtocol.o" \
    -framework IOKit -framework IOUSBHost -framework Security -framework Network \
    -framework CFNetwork -framework SystemConfiguration -framework Charts \
    -framework ServiceManagement -framework UserNotifications \
    -o "$OUT/EC25Toolbox"

echo "== done"
ls -la "$OUT/EC25Toolbox"
file "$OUT/EC25Toolbox"
