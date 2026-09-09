import Foundation

/// Private Drive metadata keys and query escaping shared by discovery paths.
enum GoogleDriveMetadata {
    enum Key: String {
        case objectKey = "librereverseObjectKey"
        case root = "librereverseRoot"
    }

    static func value(_ key: Key, in properties: [String: String]?) -> String? {
        properties?[key.rawValue]
    }

    static func query(_ key: Key, equals value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "appProperties has { key='\(key.rawValue)' and value='\(escaped)' }"
    }
}
