import XCTest
@testable import ScamShield

final class NotificationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ bucket: Bucket, hoursAgo: Double, done: Bool = false) -> Item {
        var item = Item(id: id, bucket: bucket, category: bucket.defaultCategory)
        item.date = now.addingTimeInterval(-hoursAgo * 3600)
        item.done = done
        return item
    }

    func testOnlyRecentOpenUnnotifiedAttentionItems() {
        let items = [
            item("fresh", .attention, hoursAgo: 1),
            item("old", .attention, hoursAgo: 25),
            item("done", .attention, hoursAgo: 1, done: true),
            item("seen", .attention, hoursAgo: 2),
            item("review", .review, hoursAgo: 1),
            item("scam", .scam, hoursAgo: 1),
        ]
        let due = NotificationPlanner.itemsToNotify(items, notified: ["seen"], now: now)
        XCTAssertEqual(due.map(\.id), ["fresh"])
    }

    func testItemWithoutDateIsNeverNotified() {
        let undated = Item(id: "x", bucket: .attention, category: "personal")
        XCTAssertTrue(NotificationPlanner.itemsToNotify([undated], notified: [], now: now).isEmpty)
    }

    func testBodyAddsCallBackHint() {
        var item = item("a", .attention, hoursAgo: 1)
        item.summary = "Confirming your cleaning"
        XCTAssertEqual(NotificationPlanner.body(for: item), "Confirming your cleaning")
        item.callback = Item.Callback(recommended: true, probability: 0.8)
        XCTAssertEqual(NotificationPlanner.body(for: item), "Confirming your cleaning · Call back")
        item.summary = nil
        XCTAssertEqual(NotificationPlanner.body(for: item), "Missed call · Call back")
    }

    func testTitleUsesContactThenOrganizationThenNumber() {
        var item = item("a", .attention, hoursAgo: 1)
        item.number = "+15550100001"
        item.displayNumber = "(555) 010-0001"
        XCTAssertEqual(NotificationPlanner.title(for: item), "(555) 010-0001")
        item.caller = Item.Caller(name: "Dana", organization: "Bayview Dental")
        XCTAssertEqual(NotificationPlanner.title(for: item), "Bayview Dental")
        item.contactName = "Dana Smith"
        XCTAssertEqual(NotificationPlanner.title(for: item), "Dana Smith")
    }

    func testLedgerForgetsOnlyLongAfterTheWindow() {
        let ledger = ["recent": now.addingTimeInterval(-3600), "ancient": now.addingTimeInterval(-NotificationPlanner.memory - 1)]
        XCTAssertEqual(Set(NotificationPlanner.trimmed(ledger, now: now).keys), ["recent"])
        XCTAssertGreaterThan(NotificationPlanner.memory, NotificationPlanner.window)
    }
}
