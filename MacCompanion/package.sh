#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be major.minor.patch" >&2
  exit 2
fi
OUTPUT="$ROOT/build/agentOS-Companion-$VERSION-$(uname -m).pkg"
mkdir -p "$ROOT/build"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/root/Applications/agentOS Companion.app"
bash "$ROOT/MacCompanion/build.sh" "$APP"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
# Re-sign after adding version and license resources; this is an ad-hoc development signature.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$STAGE/components.plist"
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" \
  --identifier com.agentos.companion.installer --version "$VERSION" \
  --install-location / --ownership recommended "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Installer: $OUTPUT"
echo "Development package: not Developer ID signed or notarized."
