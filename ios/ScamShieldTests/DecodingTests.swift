import XCTest
@testable import ScamShield

final class DecodingTests: XCTestCase {
    func testItemWithOmittedKeysUsesDefaults() throws {
        let json = """
        {"version": 1, "generatedAt": "2026-11-17T17:40:00Z",
         "items": [{"id": "call:1", "number": "+15550100001", "date": "2026-11-17T17:13:56Z",
                    "bucket": "review", "category": "no_message"}]}
        """
        let inbox = try Inbox.decode(Data(json.utf8))
        let item = try XCTUnwrap(inbox.items.first)
        XCTAssertNil(item.contactName)
        XCTAssertNil(item.voicemail)
        XCTAssertNil(item.caller)
        XCTAssertNil(item.summary)
        XCTAssertNil(item.reputation)
        XCTAssertEqual(item.reasons, [])
        XCTAssertEqual(item.callCount, 1)
        XCTAssertFalse(item.done)
        XCTAssertFalse(item.callbackRecommended)
        XCTAssertEqual(item.title, "+15550100001")
        XCTAssertNil(inbox.mac)
        XCTAssertEqual(inbox.generatedAt, JSON.parseDate("2026-11-17T17:40:00Z"))
    }

    func testNestedOmittedKeysAndFractionalDates() throws {
        let json = """
        {"items": [{"id": "vm:2", "number": "", "date": "2026-11-17T17:13:56.250Z", "bucket": "scam",
                    "category": "fraud", "caller": {"organization": "Social Security Administration"},
                    "voicemail": {"id": "AB", "transcript": "Press one"},
                    "reputation": {"score": 0.9, "complaints": 12},
                    "callback": {"recommended": false}}]}
        """
        let item = try XCTUnwrap(try Inbox.decode(Data(json.utf8)).items.first)
        XCTAssertNotNil(item.date)
        XCTAssertNil(item.caller?.name)
        XCTAssertEqual(item.voicemail?.hasAudio, false)
        XCTAssertNil(item.voicemail?.audioFile)
        XCTAssertNil(item.voicemail?.durationSec)
        XCTAssertNil(item.reputation?.lastReported)
        XCTAssertNil(item.callback?.probability)
        // Scam: never title the call with the claimed identity.
        XCTAssertEqual(item.title, "No Caller ID")
        XCTAssertEqual(item.subtitle, "Claims to be Social Security Administration · Caller ID withheld")
        XCTAssertFalse(item.showsCallBack)
    }

    func testFaceTimeHandleIsNotDialable() throws {
        let json = """
        {"items": [{"id": "call:3", "number": "jordan@example.com", "bucket": "attention", "category": "personal",
                    "contactName": "Jordan"}]}
        """
        let item = try XCTUnwrap(try Inbox.decode(Data(json.utf8)).items.first)
        XCTAssertFalse(item.hasPhoneNumber)
        XCTAssertEqual(item.callBackURL?.scheme, "facetime-audio")
        XCTAssertEqual(item.callBackLabel, "Call Back with FaceTime")
    }

    func testUnreadableItemsAreSkippedNotFatal() throws {
        let json = """
        {"items": [{"id": "call:ok", "bucket": "attention", "category": "medical"},
                   {"id": "call:bad", "bucket": "someday", "category": "x"},
                   {"bucket": "review"}]}
        """
        let inbox = try Inbox.decode(Data(json.utf8))
        XCTAssertEqual(inbox.items.map(\.id), ["call:ok"])
        XCTAssertEqual(inbox.skippedItems, 2)
    }

    func testMacModelsAcceptsStringOrObject() throws {
        let a = try Inbox.decode(Data(#"{"mac": {"models": "ok"}, "items": []}"#.utf8))
        XCTAssertEqual(a.mac?.models?.isOK, true)
        let b = try Inbox.decode(Data(#"{"mac": {"models": {"decider": "ok", "writer": "down"}}, "items": []}"#.utf8))
        XCTAssertEqual(b.mac?.models?.isOK, false)
    }

    func testMalformedInboxThrows() {
        XCTAssertThrowsError(try Inbox.decode(Data("{\"items\": ".utf8)))
    }

    func testFixtureInboxDecodesCompletely() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/ScamShield/inbox.json")
        let data = try Data(contentsOf: url)
        let inbox = try Inbox.decode(data)
        XCTAssertEqual(inbox.skippedItems, 0)
        XCTAssertGreaterThanOrEqual(inbox.items.count, 15)
        let categories = Set(inbox.items.map(\.category))
        for bucket in Bucket.allCases {
            for category in bucket.categories {
                XCTAssertTrue(categories.contains(category), "fixture lacks \(category)")
            }
        }
    }

    func testCorrectionJSONOmitsNilsAndUsesPlainISODates() throws {
        let at = try XCTUnwrap(JSON.parseDate("2026-11-17T17:41:00Z"))
        let correction = Correction.done(itemId: "call:1", done: true, at: at)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: correction.encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "itemId", "action", "done", "at"])
        XCTAssertEqual(object["at"] as? String, "2026-11-17T17:41:00Z")
        XCTAssertEqual(object["action"] as? String, "done")

        let label = Correction.label(itemId: "call:1", bucket: .scam, category: "telemarketing", applyToNumber: true, at: at)
        let labelObject = try XCTUnwrap(JSONSerialization.jsonObject(with: label.encoded()) as? [String: Any])
        XCTAssertEqual(Set(labelObject.keys), ["id", "itemId", "action", "bucket", "category", "applyToNumber", "at"])
    }
}
