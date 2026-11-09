import Foundation
import Testing

@testable import Latch

@Suite
struct LatchValueHistoryTests {
    @Test("equal consecutive values collapse, a returning value is kept")
    func dedupe() {
        var history = LatchValueHistory()
        for (at, value) in [(1, "a"), (2, "a"), (3, "b"), (4, "a")] {
            history.record(id: "row", value: value, at: at)
        }
        #expect(history.entries(id: "row").map(\.value) == ["a", "b", "a"])
        #expect(history.entries(id: "row").map(\.at) == [1, 3, 4])
    }

    @Test("a ring keeps the newest entries")
    func ringIsBounded() {
        var history = LatchValueHistory()
        let total = LatchValueHistory.entriesPerID + 6
        for step in 0..<total {
            history.record(id: "row", value: "v\(step)", at: step)
        }
        let kept = history.entries(id: "row")
        #expect(kept.count == LatchValueHistory.entriesPerID)
        #expect(kept.first?.value == "v6")
        #expect(kept.last?.value == "v\(total - 1)")
    }

    @Test("the id cap evicts the least recently written id")
    func idCapEvictsStalestWriter() {
        var history = LatchValueHistory()
        for index in 0..<LatchValueHistory.idLimit {
            history.record(id: "id\(index)", value: "a", at: index)
        }
        history.record(id: "id0", value: "b", at: 1000)
        history.record(id: "newcomer", value: "a", at: 1001)
        #expect(history.entries(id: "id1").isEmpty)
        #expect(history.entries(id: "id0").map(\.value) == ["a", "b"])
        #expect(history.entries(id: "newcomer").map(\.value) == ["a"])
    }
}
