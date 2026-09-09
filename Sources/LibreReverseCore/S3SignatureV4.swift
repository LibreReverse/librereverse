#if os(macOS)
import CryptoKit
import Foundation

/// S3 canonical paths retain repeated slashes and percent-encode UTF-8 bytes.
/// https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
public enum S3SignatureV4 {
    static let emptyHash = hex(SHA256.hash(data: Data()))
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func uriEncode(_ value: String, preserveSlash: Bool = false) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45,46,95,126].contains(byte) || (preserveSlash && byte == 47) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        var pairs: [(String, String)] = items.map { (uriEncode($0.name), uriEncode($0.value ?? "")) }
        pairs.sort { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }
        let encoded: [String] = pairs.map { "\($0.0)=\($0.1)" }
        return encoded.joined(separator: "&")
    }
    public static func sign(_ original: URLRequest, configuration: S3ArchiveConfiguration,
                            payloadSHA256: String, date: Date) throws -> URLRequest {
        guard let url = original.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, payloadSHA256.count == 64,
              payloadSHA256.allSatisfy({ $0.isHexDigit }) else { throw ArchiveBackendError.invalidResponse }
        var request = original
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        request.setValue(host + (parts.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadSHA256.lowercased(), forHTTPHeaderField: "x-amz-content-sha256")
        if let token = configuration.sessionToken { request.setValue(token, forHTTPHeaderField: "x-amz-security-token") }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let headers = (request.allHTTPHeaderFields ?? [:]).map { key, value in
            (key.lowercased(), value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " "))
        }.sorted { $0.0 < $1.0 }
        let names = headers.map(\.0).joined(separator: ";")
        let canonical = [request.httpMethod ?? "GET", parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath,
                         canonicalQuery(parts.queryItems ?? []), headers.map { "\($0.0):\($0.1)\n" }.joined(),
                         names, payloadSHA256.lowercased()].joined(separator: "\n")
        let scope = "\(day)/\(configuration.region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(SHA256.hash(data: Data(canonical.utf8))))"
        func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }
        let dateKey = hmac(Data(("AWS4" + configuration.secretKey).utf8), day)
        let signingKey = hmac(hmac(hmac(dateKey, configuration.region), "s3"), "aws4_request")
        let signature = hex(hmac(signingKey, toSign))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(scope), SignedHeaders=\(names), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
}
#endif
