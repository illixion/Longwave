#!/usr/bin/env bash
#
# verify-seal-interop.sh — prove the host and the headset agree about the seal.
#
# The direct link's encryption is implemented twice: C++ over BCrypt in the OpenXR
# layer / session broker, Swift over CryptoKit in the app. They share only a comment.
# If they disagree about the key derivation, the nonce, or the AAD, then nothing opens
# and the symptom on device is "the PC does not answer" — indistinguishable from a
# firewall or a wrong address. So the two are checked against each other:
#
#   host  --vectors  ->  Swift opens it
#   Swift            ->  host --open  opens it
#
# Both directions, because a mistake that swapped the two keys would still pass a
# one-way check.
#
# Usage:  ci/verify-seal-interop.sh <host-vectors-file> [<swift-out-file>]
#
# where <host-vectors-file> is the output of `bridge_tests --vectors` run on the
# Windows host (this script does not need Windows, and the host does not need Swift).
# The script prints the client->host envelope to feed back to `bridge_tests --open`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vectors="${1:?usage: verify-seal-interop.sh <host-vectors-file> [<swift-out-file>]}"
swift_out="${2:-/dev/stdout}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

host_hex="$(awk '/^HOST_TO_CLIENT /{print $2}' "$vectors")"
plaintext="$(sed -n 's/^PLAINTEXT //p' "$vectors")"
if [[ -z "$host_hex" || -z "$plaintext" ]]; then
    echo "error: $vectors has no PLAINTEXT/HOST_TO_CLIENT lines (run bridge_tests --vectors)" >&2
    exit 1
fi

# The real BridgeSeal.swift, compiled as-is. Only its one dependency is stubbed —
# copying the implementation here would test the copy rather than the shipping code.
cat > "$work/stub.swift" <<'SWIFT'
enum ControllerBridgeProtocol { static let version: UInt8 = 2 }
SWIFT

cat > "$work/main.swift" <<SWIFT
import Foundation

let hostHex = "$host_hex"
let expected = "$plaintext"

func bytes(_ hex: String) -> Data {
    var d = Data(); var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        d.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return d
}

// The token both sides agree on for the vectors: (i * 7 + 1) & 0xff.
let token = Data((0..<32).map { UInt8((\$0 * 7 + 1) & 0xff) })

var seal = BridgeSeal(token: token)
guard let opened = seal.open(bytes(hostHex)) else {
    print("FAIL: the host's envelope did not open in Swift")
    exit(1)
}
guard String(decoding: opened, as: UTF8.self) == expected else {
    print("FAIL: opened plaintext differs from the host's")
    exit(1)
}
print("OK: Swift opened the host's host->client envelope")

// Now the other direction, for the host to open.
var out = BridgeSeal(token: token)
guard let sealed = out.seal(Data(expected.utf8)) else {
    print("FAIL: Swift could not seal")
    exit(1)
}
print("CLIENT_TO_HOST " + sealed.map { String(format: "%02x", \$0) }.joined())
SWIFT

swiftc -O -DFOVEATED_ENABLED \
    "$repo_root/Longwave/ControllerBridge/BridgeSeal.swift" \
    "$work/stub.swift" "$work/main.swift" \
    -o "$work/sealcheck"

"$work/sealcheck" | tee "$swift_out"
