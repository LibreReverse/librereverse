#if os(macOS)
import CXID
import CryptoKit
import Darwin
import Foundation
import Security

/// Generates sortable identifiers using the 12-byte XID layout.
/// Adapted from the swift-xid algorithm; see licenses/Swift-XID.txt and
/// THIRD_PARTY_NOTICES.md for attribution and implementation provenance.
public enum XID {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuv".utf8)

    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 20 && bytes.allSatisfy(alphabet.contains)
    }

    public static func generate(at date: Date = Date()) -> String {
        _ = State.counterInitialized
        return string(
            timestamp: UInt32(date.timeIntervalSince1970),
            machineIdentifier: State.machineIdentifier,
            processIdentifier: UInt16(truncatingIfNeeded: getpid()),
            counter: xid_next_counter()
        )
    }

    /// Deterministic encoding boundary used to verify the exact 12-byte layout
    /// independently of the current machine, process, clock, and atomic seed.
    public static func string(
        timestamp: UInt32,
        machineIdentifier: [UInt8],
        processIdentifier: UInt16,
        counter: UInt32
    ) -> String {
        precondition(machineIdentifier.count == 3)
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: timestamp >> 24),
            UInt8(truncatingIfNeeded: timestamp >> 16),
            UInt8(truncatingIfNeeded: timestamp >> 8),
            UInt8(truncatingIfNeeded: timestamp),
            machineIdentifier[0], machineIdentifier[1], machineIdentifier[2],
            UInt8(truncatingIfNeeded: processIdentifier >> 8),
            UInt8(truncatingIfNeeded: processIdentifier),
            UInt8(truncatingIfNeeded: counter >> 16),
            UInt8(truncatingIfNeeded: counter >> 8),
            UInt8(truncatingIfNeeded: counter),
        ]
        return encode(bytes)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 12)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(20)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                encoded.append(alphabet[Int((accumulator >> bitCount) & 0x1f)])
            }
        }
        if bitCount > 0 {
            encoded.append(alphabet[Int((accumulator << (5 - bitCount)) & 0x1f)])
        }
        precondition(encoded.count == 20)
        return String(decoding: encoded, as: UTF8.self)
    }

    private enum State {
        static let machineIdentifier: [UInt8] = {
            var hostUUID = [UInt8](repeating: 0, count: 16)
            var timeout = timespec(tv_sec: 0, tv_nsec: 500_000_000)
            hostUUID.withUnsafeMutableBytes { raw in
                _ = gethostuuid(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), &timeout)
            }
            return Array(Insecure.MD5.hash(data: Data(hostUUID)).prefix(3))
        }()

        static let counterInitialized: Void = {
            var seed: UInt32 = 0
            if SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &seed)
                != errSecSuccess
            {
                seed = UInt32.random(in: UInt32.min...UInt32.max)
            }
            xid_initialize_counter(seed)
        }()
    }
}
#endif
