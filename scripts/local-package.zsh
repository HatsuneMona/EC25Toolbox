#!/bin/zsh
# Assemble a local app using installed 27.1 resources/helpers and the rebuilt binary.
# Build first with: zsh scripts/local-build.zsh
# No installation, quitting, preference changes, or source-app modifications occur.
set -euo pipefail
ROOT="${0:A:h:h}"
BASE_APP="${1:-/Applications/EC25 Toolbox.app}"
BINARY="$ROOT/.build/local-clt/manual/EC25Toolbox"
APP="$ROOT/dist/EC25 Toolbox.app"
if [[ ! -d "$BASE_APP/Contents/Resources/EC25Toolbox_EC25Toolbox.bundle" || ! -x "$BINARY" ]]; then
  print -u2 'A compatible EC25 Toolbox 27.1 app and rebuilt binary are required.'
  exit 1
fi
if [[ -e "$APP" ]]; then
  print -u2 "Output already exists: $APP. Move it aside before packaging again."
  exit 1
fi
BASE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BASE_APP/Contents/Info.plist")
if [[ "$BASE_VERSION" != '27.1' ]]; then
  print -u2 "Expected base app 27.1; found $BASE_VERSION."
  exit 1
fi
mkdir -p "$ROOT/dist"
/usr/bin/ditto "$BASE_APP" "$APP"
/bin/cp "$BINARY" "$APP/Contents/MacOS/EC25Toolbox"
/usr/bin/ditto "$ROOT/Sources/EC25Toolbox/Resources" \
  "$APP/Contents/Resources/EC25Toolbox_EC25Toolbox.bundle/Contents/Resources"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
print "Packaged: $APP"
