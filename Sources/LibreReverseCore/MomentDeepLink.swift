import Foundation

/// Durable links to moments in the LibreReverse library.
public enum MomentDeepLink {
    public static let nativeScheme = "librereverse"
    public static let host = "show-moment"

    public static func url(
        for date: Date
    ) -> URL? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var components = URLComponents()
        components.scheme = nativeScheme
        components.host = host
        components.queryItems = [
            URLQueryItem(
                name: "timestamp",
                value: String(date.timeIntervalSince1970)
            )
        ]
        return components.url
    }

    public static func date(from url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == nativeScheme,
            components.host == host,
            components.path.isEmpty,
            let value = components.queryItems?.first(where: { $0.name == "timestamp" })?.value,
            let timestamp = Double(value),
            timestamp.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}
