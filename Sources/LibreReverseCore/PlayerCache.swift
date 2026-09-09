import Foundation

/// Bounded least-recently-used player ordering. This policy owns no
/// AVFoundation objects; the caller manages player reuse and release.
public enum PlayerCache {
    /// Maximum number of retained players.
    public static let capacity = 5

    public struct Entry<Key: Hashable & Sendable>: Equatable, Sendable {
        public var key: Key
        public var lastUsed: Date

        public init(key: Key, lastUsed: Date) {
            self.key = key
            self.lastUsed = lastUsed
        }
    }

    public struct Outcome<Key: Hashable & Sendable>: Equatable, Sendable {
        /// Retained entries, least recently used first.
        public var entries: [Entry<Key>]
        /// Keys dropped by this access, least recently used first.
        public var evicted: [Key]
        /// True when the key was not retained. At capacity the caller can replace
        /// the item in the least-recently-used player.
        public var created: Bool

        public init(entries: [Entry<Key>], evicted: [Key], created: Bool) {
            self.entries = entries
            self.evicted = evicted
            self.created = created
        }
    }

    /// Restamps or appends the accessed key, sorts by recency, and drops entries
    /// beyond capacity. The caller can recycle the evicted player for the new item.
    public static func access<Key: Hashable & Sendable>(
        _ entries: [Entry<Key>],
        key: Key,
        at date: Date
    ) -> Outcome<Key> {
        var retained = entries
        let existing = retained.firstIndex { $0.key == key }
        if let existing {
            retained[existing].lastUsed = date
        } else {
            retained.append(Entry(key: key, lastUsed: date))
        }

        // Equal access dates have no additional ordering constraint.
        retained.sort { $0.lastUsed < $1.lastUsed }

        let dropCount = retained.count < capacity ? 0 : retained.count - capacity
        let evicted = retained.prefix(dropCount).map(\.key)
        retained.removeFirst(dropCount)

        return Outcome(entries: retained, evicted: evicted, created: existing == nil)
    }

    /// Removes a failed cache identity while preserving all other recency order,
    /// so a retry constructs fresh media state.
    public static func removing<Key: Hashable & Sendable>(
        _ key: Key,
        from entries: [Entry<Key>]
    ) -> [Entry<Key>] {
        entries.filter { $0.key != key }
    }
}
