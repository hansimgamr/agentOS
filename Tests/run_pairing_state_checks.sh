#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
/usr/bin/sed -e '/^import UIKit$/d' -e 's/UIDevice.current.name/"Fixture iPhone"/g' \
    -e 's/KeychainStore/TestKeychainStore/g' -e 's/HermesAPI/TestHermesAPI/g' -e 's/LAContext/TestLAContext/g' \
    "$ROOT/HermesPocket/ChatStore.swift" > "$TMP/ChatStore.swift"
swiftc "$ROOT/Shared/DeviceAuthentication.swift" "$ROOT/HermesPocket/Models.swift" "$ROOT/Tests/PairingStateDoubles.swift" \
    "$TMP/ChatStore.swift" "$ROOT/Tests/PairingStateChecks.swift" -o "$TMP/pairing-state-checks"
"$TMP/pairing-state-checks"
