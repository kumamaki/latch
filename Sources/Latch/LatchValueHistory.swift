#if DEBUG
    import Foundation

    /// Bounded record of the values a catalog id has published.
    ///
    /// Keyed by id, not by registration, so a list row that unmounts and
    /// remounts keeps its past. Time is milliseconds on the caller's
    /// monotonic clock.
    struct LatchValueHistory {
        struct Entry: Sendable, Equatable, Encodable {
            let at: Int
            let value: String
        }

        static let entriesPerID = 64
        static let idLimit = 256

        private struct Ring {
            var entries: [Entry]
            var lastWrite: Int
        }

        private var rings: [String: Ring] = [:]
        private var writeCount = 0

        /// Appends `value` unless it equals the last recorded one.
        mutating func record(id: String, value: String, at milliseconds: Int) {
            if rings[id]?.entries.last?.value == value { return }
            if rings[id] == nil, rings.count >= Self.idLimit {
                evictLeastRecentlyWritten()
            }
            writeCount += 1
            var ring = rings[id] ?? Ring(entries: [], lastWrite: 0)
            ring.entries.append(Entry(at: milliseconds, value: value))
            if ring.entries.count > Self.entriesPerID {
                ring.entries.removeFirst()
            }
            ring.lastWrite = writeCount
            rings[id] = ring
        }

        func entries(id: String) -> [Entry] {
            rings[id]?.entries ?? []
        }

        mutating func removeAll() {
            rings.removeAll()
            writeCount = 0
        }

        private mutating func evictLeastRecentlyWritten() {
            guard let oldest = rings.min(by: { $0.value.lastWrite < $1.value.lastWrite }) else {
                return
            }
            rings.removeValue(forKey: oldest.key)
        }
    }

    /// The `history` field of an `axFind` reply.
    struct LatchHistoryReply: Sendable, Equatable, Encodable {
        /// The recorder's clock at reply time, so a caller can relate
        /// entries to something it did a moment ago.
        let now: Int
        let entries: [LatchValueHistory.Entry]
    }
#endif
