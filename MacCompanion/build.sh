#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-/tmp/agentOS Companion.app}"
if [[ "$APP" != *.app ]]; then
  echo "Output path must end in .app" >&2
  exit 2
fi
PARENT="$(dirname "$APP")"
mkdir -p "$PARENT"
STAGE="$(mktemp -d "$PARENT/.agentos-companion.XXXXXX")"
CONTENTS="$STAGE/Contents"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/MacRelay"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$ROOT/MacCompanion/main.swift" -o "$CONTENTS/MacOS/agentOS Companion" \
  -framework SwiftUI -framework AppKit -framework CoreImage
cp "$ROOT/MacRelay/companion.py" "$ROOT/MacRelay/credentials.py" "$ROOT/MacRelay/relay.py" "$CONTENTS/Resources/MacRelay/"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>agentOS Companion</string>
  <key>CFBundleIdentifier</key><string>com.agentos.companion</string>
  <key>CFBundleName</key><string>agentOS Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$STAGE"
if [[ -L "$APP" ]]; then
  echo "Refusing to replace a symbolic link: $APP" >&2
  exit 2
fi
if [[ -e "$APP" ]]; then
  if [[ ! -d "$APP" ]]; then
    echo "Refusing to replace a non-bundle path: $APP" >&2
    exit 2
  fi
  IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$IDENTIFIER" != "com.agentos.companion" || "$EXECUTABLE" != "agentOS Companion" || ! -x "$APP/Contents/MacOS/agentOS Companion" ]]; then
    echo "Refusing to replace a bundle this script did not create: $APP" >&2
    exit 2
  fi
  rm -rf "$APP"
fi
mv "$STAGE" "$APP"
trap - EXIT
echo "Built $APP"
