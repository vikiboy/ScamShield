import XCTest
@testable import ScamShield

final class OverlayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, bucket: Bucket = .attention, category: String = "medical", done: Bool = false) -> Item {
        var item = Item(id: id, bucket: bucket, category: category)
        item.done = done
        return item
    }

    private func inbox(_ items: [Item], generatedAt: Date) -> Inbox {
        Inbox(generatedAt: generatedAt, items: items)
    }

    func testDoneAndLabelAreOverlaid() {
        let items = [item("a"), item("b")]
        var pending = Overlay.adding(.done(itemId: "a", done: true, at: t0), to: [], written: true)
        pending = Overlay.adding(.label(itemId: "b", bucket: .scam, category: "fraud", applyToNumber: false, at: t0),
                                 to: pending, written: true)
        let shown = Overlay.apply(pending, to: items)
        XCTAssertTrue(shown[0].done)
        XCTAssertEqual(shown[1].bucket, .scam)
        XCTAssertEqual(shown[1].category, "fraud")
        XCTAssertTrue(shown[1].userLabeled)
    }

    func testPendingKeptWhileInboxIsOlderAndUnchanged() {
        let pending = Overlay.adding(.done(itemId: "a", done: true, at: t0), to: [], written: true)
        let stale = inbox([item("a")], generatedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(Overlay.prune(pending, against: stale).count, 1)
    }

    func testPendingDroppedWhenInboxReflectsIt() {
        let pending = Overlay.adding(.done(itemId: "a", done: true, at: t0), to: [], written: true)
        let caughtUp = inbox([item("a", done: true)], generatedAt: t0.addingTimeInterval(10))
        XCTAssertTrue(Overlay.prune(pending, against: caughtUp).isEmpty)
    }

    func testPendingDroppedAfterGracePeriod() {
        let pending = Overlay.adding(.label(itemId: "a", bucket: .review, category: "unclear", applyToNumber: true, at: t0),
                                     to: [], written: true)
        let later = inbox([item("a")], generatedAt: t0.addingTimeInterval(Overlay.grace + 1))
        XCTAssertTrue(Overlay.prune(pending, against: later).isEmpty)
        let justInside = inbox([item("a")], generatedAt: t0.addingTimeInterval(Overlay.grace - 1))
        XCTAssertEqual(Overlay.prune(pending, against: justInside).count, 1)
    }

    func testUnwrittenCorrectionsSurvivePruning() {
        let pending = Overlay.adding(.done(itemId: "a", done: true, at: t0), to: [], written: false)
        let later = inbox([item("a", done: true)], generatedAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(Overlay.prune(pending, against: later).count, 1)
    }

    /// Done then Undo before the Mac catches up: the Undo supersedes the Done, so once the stale
    /// inbox (done = false) "matches" the Undo, nothing is left forcing the item to done.
    func testUndoSupersedesEarlierDone() {
        var pending = Overlay.adding(.done(itemId: "a", done: true, at: t0), to: [], written: true)
        pending = Overlay.adding(.done(itemId: "a", done: false, at: t0.addingTimeInterval(2)), to: pending, written: true)
        XCTAssertEqual(pending.count, 1)
        let stale = inbox([item("a")], generatedAt: t0.addingTimeInterval(-30))
        XCTAssertFalse(Overlay.apply(pending, to: stale.items)[0].done)
        let pruned = Overlay.prune(pending, against: stale)
        XCTAssertTrue(pruned.isEmpty)
        XCTAssertFalse(Overlay.apply(pruned, to: stale.items)[0].done)
    }

    func testDifferentActionsOnSameItemCoexist() {
        var pending = Overlay.adding(.label(itemId: "a", bucket: .scam, category: "fraud", applyToNumber: false, at: t0),
                                     to: [], written: true)
        pending = Overlay.adding(.done(itemId: "a", done: true, at: t0.addingTimeInterval(1)), to: pending, written: true)
        let shown = Overlay.apply(pending, to: [item("a")])[0]
        XCTAssertEqual(shown.bucket, .scam)
        XCTAssertTrue(shown.done)
    }

    func testBlockDoesNotMoveItemAndOnlyExpiresByTime() {
        let pending = Overlay.adding(.block(itemId: "a", number: "+15550100001", block: true, at: t0), to: [], written: true)
        XCTAssertEqual(Overlay.apply(pending, to: [item("a")])[0].bucket, .attention)
        XCTAssertEqual(Overlay.prune(pending, against: inbox([item("a", bucket: .scam, category: "blocked")],
                                                             generatedAt: t0)).count, 1)
        XCTAssertTrue(Overlay.prune(pending, against: inbox([], generatedAt: t0.addingTimeInterval(600))).isEmpty)
    }
}
