#!/usr/bin/env swift

import CryptoKit
import Foundation

struct Manifest: Codable {
    let version: String
    let build: Int
    let downloadURL: URL
    let releaseNotesURL: URL?
    let sha256: String
}

struct Envelope: Codable {
    let payload: String
    let signature: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 6 || arguments.count == 7 else {
    fail("usage: make_signed_update_manifest.swift VERSION BUILD DOWNLOAD_URL SHA256 OUTPUT [RELEASE_NOTES_URL]")
}
guard !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("VERSION must not be empty") }
guard let build = Int(arguments[2]), build > 0 else { fail("BUILD must be positive") }
guard let downloadURL = URL(string: arguments[3]), downloadURL.scheme?.lowercased() == "https",
      let host = downloadURL.host, !host.isEmpty,
      downloadURL.user == nil, downloadURL.password == nil else {
    fail("DOWNLOAD_URL must use HTTPS with a host and no embedded credentials")
}
let sha256 = arguments[4].lowercased()
guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
    fail("SHA256 must be exactly 64 hexadecimal characters")
}
let releaseNotesURL: URL?
if arguments.count == 7 {
    guard let url = URL(string: arguments[6]), url.scheme?.lowercased() == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
        fail("RELEASE_NOTES_URL must use HTTPS with a host and no embedded credentials")
    }
    releaseNotesURL = url
} else {
    releaseNotesURL = nil
}
guard let encodedPrivateKey = ProcessInfo.processInfo.environment[
    "LIBREREVERSE_UPDATE_PRIVATE_KEY"
], let privateKeyData = Data(base64Encoded: encodedPrivateKey) else {
    fail("LIBREREVERSE_UPDATE_PRIVATE_KEY must contain a base64 Curve25519 signing key")
}
let privateKey: Curve25519.Signing.PrivateKey
do {
    privateKey = try .init(rawRepresentation: privateKeyData)
} catch {
    fail("LIBREREVERSE_UPDATE_PRIVATE_KEY is invalid")
}

let payloadEncoder = JSONEncoder()
payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let payload: Data
do {
    payload = try payloadEncoder.encode(
        Manifest(
            version: arguments[1],
            build: build,
            downloadURL: downloadURL,
            releaseNotesURL: releaseNotesURL,
            sha256: sha256
        )
    )
} catch {
    fail("could not encode manifest: \(error.localizedDescription)")
}
let signature: Data
do {
    signature = try privateKey.signature(for: payload)
} catch {
    fail("could not sign manifest: \(error.localizedDescription)")
}
let envelope = Envelope(
    payload: payload.base64EncodedString(),
    signature: signature.base64EncodedString()
)
let envelopeEncoder = JSONEncoder()
envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try envelopeEncoder.encode(envelope).write(
        to: URL(fileURLWithPath: arguments[5]),
        options: .atomic
    )
} catch {
    fail("could not write envelope: \(error.localizedDescription)")
}

print("manifest: \(arguments[5])")
print("public key: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
