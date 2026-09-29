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
  "$ROOT/MacCompanion/main.swift" "$ROOT/Shared/NearbyPairingProtocol.swift" "$ROOT/Shared/WelcomeTour.swift" \
  -o "$CONTENTS/MacOS/agentOS Companion" \
  -framework SwiftUI -framework AppKit -framework CoreImage -framework CryptoKit -framework MultipeerConnectivity
cp "$ROOT/MacRelay/companion.py" "$ROOT/MacRelay/setup_connection.py" "$ROOT/MacRelay/credentials.py" "$ROOT/MacRelay/relay.py" "$CONTENTS/Resources/MacRelay/"
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
  <key>NSLocalNetworkUsageDescription</key><string>agentOS Companion uses your local network to securely pair with a nearby iPhone when you choose Pair nearby.</string>
  <key>NSBonjourServices</key>
  <array><string>_agentos-pair._tcp</string><string>_agentos-pair._udp</string></array>
</dict>
</plist>
PLIST
xcrun actool "$ROOT/Design/AppIcon/AgentOS.icon" --compile "$CONTENTS/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AgentOS \
  --output-partial-info-plist "$STAGE/icon-info.plist" --output-format human-readable-text
/usr/libexec/PlistBuddy -c "Merge $STAGE/icon-info.plist" "$CONTENTS/Info.plist"
rm "$STAGE/icon-info.plist"
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
