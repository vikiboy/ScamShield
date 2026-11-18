import XCTest
import CryptoKit
@testable import ScamShieldCore

final class ClassifierTests: XCTestCase {
    func judgment(_ top: String, _ p: Double, callback: Double = 0.1, automated: Double = 0.3, specific: Double = 0.3) -> ContentJudgment {
        let cats = ["personal", "appointment_or_medical", "delivery_or_service", "work_or_recruiter", "account_legit",
                    "fraud_impersonation", "loan_or_debt_offer", "sales_telemarketing", "robocall_other", "silent_or_unclear"]
        var probs: [String: Double] = [:]
        for c in cats { probs[c] = (1 - p) / Double(cats.count - 1) }
        probs[top] = p
        return ContentJudgment(categoryProbs: probs, callback: callback, fraud: 0.3, specific: specific, automated: automated)
    }

    func testLoanRobocallGoesToScams() {
        let d = Classifier.decide(context: CallerContext(), voicemail: nil, judgment: judgment("loan_or_debt_offer", 0.85, automated: 0.8))
        XCTAssertEqual(d.bucket, .scam); XCTAssertEqual(d.category, "loan_offer"); XCTAssertFalse(d.callbackRecommended)
    }

    func testAppointmentGoesToAttentionWithCallback() {
        let d = Classifier.decide(context: CallerContext(), voicemail: nil, judgment: judgment("appointment_or_medical", 0.7, callback: 0.1))
        XCTAssertEqual(d.bucket, .attention); XCTAssertEqual(d.category, "appointment"); XCTAssertTrue(d.callbackRecommended)
    }

    func testContactNeverScamEvenIfContentLooksScammy() {
        let ctx = CallerContext(contactName: "Mom", reputation: Reputation(score: 0.9, complaints: 20))
        let d = Classifier.decide(context: ctx, voicemail: nil, judgment: judgment("fraud_impersonation", 0.9))
        XCTAssertEqual(d.bucket, .attention)
    }

    func testModeratelyLegitContentNeverAutoScam() {
        // 25% legit mass, 75% loan: ambiguous → Review, not Scams.
        var j = judgment("loan_or_debt_offer", 0.6, automated: 0.9, specific: 0.1)
        j.categoryProbs["account_legit"] = 0.25
        let d = Classifier.decide(context: CallerContext(reputation: Reputation(score: 0.9, complaints: 30)), voicemail: nil, judgment: j)
        XCTAssertEqual(d.bucket, .review)
    }

    func testNoMessageUnknownIsReview() {
        let d = Classifier.decide(context: CallerContext(), voicemail: nil, judgment: nil)
        XCTAssertEqual(d.bucket, .review); XCTAssertEqual(d.category, "no_message")
    }

    func testNoMessageHeavilyReportedIsScam() {
        let d = Classifier.decide(context: CallerContext(reputation: Reputation(score: 0.8, complaints: 12, robocallShare: 0.9)), voicemail: nil, judgment: nil)
        XCTAssertEqual(d.bucket, .scam); XCTAssertEqual(d.category, "robocall")
    }

    func testRepeatedCallerWithCleanReputationNeedsAttention() {
        let d = Classifier.decide(context: CallerContext(callsLast15m: 2), voicemail: nil, judgment: nil)
        XCTAssertEqual(d.bucket, .attention); XCTAssertEqual(d.category, "repeated_caller")
    }

    func testUserRuleWins() {
        let d = Classifier.decide(context: CallerContext(contactName: "X", userRule: .scam, userRuleCategory: "telemarketing"), voicemail: nil, judgment: nil)
        XCTAssertEqual(d.bucket, .scam); XCTAssertEqual(d.category, "telemarketing")
    }

    func testCalendarMatchPromotes() {
        let d = Classifier.decide(context: CallerContext(calendarMatch: "Dentist"), voicemail: nil, judgment: judgment("silent_or_unclear", 0.6))
        XCTAssertEqual(d.bucket, .attention)
    }

    func testCalendarMatchDoesNotOverrideScamContent() {
        let d = Classifier.decide(context: CallerContext(calendarMatch: "Trip to Houston"), voicemail: nil, judgment: judgment("loan_or_debt_offer", 0.8))
        XCTAssertEqual(d.bucket, .scam)
    }

    func testOrgRuleScam() {
        // Org scam rule files unclear content as scam…
        XCTAssertEqual(Classifier.decide(context: CallerContext(orgRule: .scam), voicemail: nil, judgment: judgment("silent_or_unclear", 0.9)).bucket, .scam)
        // …but cannot override clearly legitimate content (caller-claimed names are spoofable).
        XCTAssertEqual(Classifier.decide(context: CallerContext(orgRule: .scam), voicemail: nil, judgment: judgment("account_legit", 0.6)).bucket, .attention)
    }
}

final class PairingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func call(_ id: String, _ num: String, _ dt: TimeInterval, duration: Double = 0, originated: Bool = false) -> AppleCall {
        AppleCall(uniqueID: id, date: t0.addingTimeInterval(dt), duration: duration, originated: originated, answered: duration > 0, number: num, provider: "com.apple.Telephony")
    }
    func vm(_ id: String, _ num: String, _ dt: TimeInterval, callUUID: String? = nil) -> AppleVoicemail {
        AppleVoicemail(id: id, callUUID: callUUID, date: t0.addingTimeInterval(dt), duration: 20, number: num, transcript: "hi", transcriptConfidence: 0.9, audioPath: nil, isRead: false)
    }

    func testPairsByUUIDThenByNumberWindow() {
        let calls = [call("A", "+15550100001", 0), call("B", "+15550100002", 100), call("C", "+15550100003", 200, duration: 30)]
        let vms = [vm("V1", "+15550100001", 40, callUUID: "A"), vm("V2", "5550100002", 160), vm("V3", "+15550100009", 300)]
        let c = Engine.pairCandidates(calls: calls, voicemails: vms)
        XCTAssertEqual(c.map(\.id), ["call:A", "call:B", "vm:V3"])   // answered call C is not a candidate
        XCTAssertEqual(c[0].voicemail?.id, "V1")
        XCTAssertEqual(c[1].voicemail?.id, "V2")
    }

    func testVoicemailOutsideWindowIsStandalone() {
        let c = Engine.pairCandidates(calls: [call("A", "+15550100001", 0)], voicemails: [vm("V1", "+15550100001", 3600)])
        XCTAssertEqual(c.map(\.id), ["call:A", "vm:V1"])
    }
}

final class UtilTests: XCTestCase {
    func testPhoneNormalize() {
        XCTAssertEqual(PhoneNumber.normalize("(555) 010-1234"), "+15550101234")
        XCTAssertEqual(PhoneNumber.normalize("1-555-010-1234"), "+15550101234")
        XCTAssertEqual(PhoneNumber.normalize("+855671750"), "+855671750")
        XCTAssertEqual(PhoneNumber.display("+15550101234"), "(555) 010-1234")
        XCTAssertEqual(PhoneNumber.key("+1 (555) 010-1234"), "5550101234")
    }

    func testParseExtractionTolerant() {
        let x = Brain.parseExtraction("```json\n{\"caller_name\": \"Dana\", \"organization\": null, \"summary\": \"Hi.\"}\n```")
        XCTAssertEqual(x["caller_name"], "Dana"); XCTAssertNil(x["organization"]); XCTAssertEqual(x["summary"], "Hi.")
    }

    func testCaptionDecode() throws {
        // Build a synthetic keyed archive shaped like Apple's: an NSArray of objects with text/confidence.
        let arch = NSKeyedArchiver(requiringSecureCoding: false)
        arch.setClassName("TUCaption", for: FakeCaption.self)
        arch.encode([FakeCaption("Hello there.", 90), FakeCaption(" Call me back.", 80)] as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        arch.finishEncoding()
        let caps = try XCTUnwrap(AppleSources.decodeCaptions(arch.encodedData))
        XCTAssertEqual(caps.map(\.text).joined(), "Hello there. Call me back.")
        XCTAssertEqual(caps.first?.confidence, 90)
    }

    func testReputationScoring() throws {
        let path = NSTemporaryDirectory() + "rep-\(UUID().uuidString).sqlite"
        let store = try Store(path: path)
        let now = Date()
        _ = try store.addComplaints((0..<6).map { i in
            (source: "fcc", sid: "r\(i)", number: "555-010-7777", date: now.addingTimeInterval(-Double(i) * 86400), state: ["CA", "TX", "NY"][i % 3], robo: true, subject: nil)
        })
        _ = try store.addComplaints([(source: "fcc", sid: "single", number: "555-010-8888", date: now, state: "CA", robo: false, subject: nil)])
        let heavy = store.reputation("+15550107777"), single = store.reputation("+15550108888"), none = store.reputation("+15550109999")
        XCTAssertGreaterThan(heavy.score, 0.6); XCTAssertEqual(heavy.complaints, 6); XCTAssertEqual(heavy.robocallShare, 1)
        XCTAssertLessThan(single.score, 0.15)
        XCTAssertEqual(none, .clean)
    }

    func testWebPushRoundTrip() throws {
        let ua = P256.KeyAgreement.PrivateKey()
        let auth = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let msg = Data(#"{"title":"Bayview Dental","body":"Call back"}"#.utf8)
        let body = try WebPush.encrypt(msg, p256dh: ua.publicKey.x963Representation.base64URL, auth: auth.base64URL)
        XCTAssertEqual(try WebPush.decrypt(body, uaPrivate: ua, auth: auth), msg)
        XCTAssertEqual(body[20], 65)   // idlen = uncompressed P-256 point
    }

    func testVAPIDJWTVerifies() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory() + "vapid-\(UUID().uuidString)")
        let wp = try WebPush(keyFile: f, subject: "mailto:test@example.com")
        let jwt = try wp.vapidJWT(audience: "https://web.push.apple.com")
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64URL: parts[2])!)
        let pub = try P256.Signing.PublicKey(x963Representation: Data(base64URL: wp.publicKeyBase64URL)!)
        XCTAssertTrue(pub.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
        // Key persists across instances.
        XCTAssertEqual(try WebPush(keyFile: f, subject: "x").publicKeyBase64URL, wp.publicKeyBase64URL)
    }
}

@objc(FakeCaption) final class FakeCaption: NSObject, NSCoding {
    let text: String; let confidence: Double
    init(_ t: String, _ c: Double) { text = t; confidence = c }
    func encode(with c: NSCoder) { c.encode(text, forKey: "text"); c.encode(confidence, forKey: "confidence"); c.encode(0, forKey: "location") }
    init?(coder: NSCoder) { text = ""; confidence = 0 }
}

final class ReviewFixTests: XCTestCase {
    func makeEngine() throws -> Engine {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("questions.json"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("extract_system.txt"), atomically: true, encoding: .utf8)
        var cfg = Config(); cfg.deciderURL = "http://127.0.0.1:1/x"; cfg.writerURL = "http://127.0.0.1:1/y"
        return Engine(config: cfg, store: try Store(path: dir.appendingPathComponent("db.sqlite").path),
                      sources: AppleSources(snapshotDir: dir), brain: try Brain(config: cfg, promptsDir: dir),
                      context: PersonalContext(useContacts: false, useCalendar: false, log: { _ in }), push: nil, log: { _ in })
    }

    func item(_ id: String) -> Item {
        Item(id: id, number: "+15550100001", displayNumber: "", contactName: nil, date: Date(), answered: false, durationSec: 0, callCount: 1,
             voicemail: nil, bucket: .scam, category: "loan_offer", confidence: 1, callback: .init(recommended: false, probability: 0),
             caller: .init(name: nil, organization: nil), summary: "", reasons: [], reputation: .init(score: 0, complaints: 0, lastReported: nil, robocallShare: 0),
             userLabeled: true, done: true, notified: true)
    }

    func vm(_ id: String) -> AppleVoicemail {
        AppleVoicemail(id: id, callUUID: nil, date: Date(), duration: 10, number: "+15550100001", transcript: "hello", transcriptConfidence: nil, audioPath: nil, isRead: true)
    }

    func testAnsweredOnAnotherDeviceIsNotMissed() {
        let c = AppleCall(uniqueID: "A", date: Date(), duration: 0, originated: false, answered: true, number: "+15550100001", provider: "com.apple.Telephony")
        XCTAssertFalse(c.isMissedIncoming)
        XCTAssertTrue(Engine.pairCandidates(calls: [c], voicemails: []).isEmpty)
    }

    func testVoicemailWhoseCallAgedOutIsNotDuplicated() throws {
        let e = try makeEngine()
        try e.store.save(item("call:A"), ItemState(callUID: "A", voicemailID: "V1", contentKey: "V1|5", judgment: nil, needsModel: false, audioPath: nil))
        XCTAssertTrue(e.dedupe([Engine.Candidate(id: "vm:V1", call: nil, voicemail: vm("V1"))]).isEmpty)
    }

    func testStandaloneVoicemailMergesIntoLaterCall() throws {
        let e = try makeEngine()
        try e.store.save(item("vm:V1"), ItemState(callUID: nil, voicemailID: "V1", contentKey: "V1|5", judgment: nil, needsModel: false, audioPath: nil))
        let call = AppleCall(uniqueID: "A", date: Date(), duration: 0, originated: false, answered: false, number: "+15550100001", provider: "com.apple.Telephony")
        let out = e.dedupe([Engine.Candidate(id: "call:A", call: call, voicemail: vm("V1"))])
        XCTAssertEqual(out.map(\.id), ["call:A"])
        XCTAssertNil(e.store.item("vm:V1"))
        try e.process(out[0], backfill: true)   // models offline → still saved, user state carried over
        let merged = try XCTUnwrap(e.store.item("call:A")?.0)
        XCTAssertTrue(merged.done); XCTAssertTrue(merged.userLabeled); XCTAssertEqual(merged.bucket, .scam)
    }

    func testTailnetAuth() {
        func req(_ h: [String: String]) -> HTTPRequest { HTTPRequest(method: "GET", path: "/api/items", query: [:], headers: h, body: Data()) }
        XCTAssertTrue(API.authorized(req([:]), allowedLogins: ["me@x.com"]))                                    // loopback
        XCTAssertFalse(API.authorized(req(["x-forwarded-for": "100.1.1.1"]), allowedLogins: []))                 // tagged node
        XCTAssertTrue(API.authorized(req(["x-forwarded-for": "100.1.1.1", "tailscale-user-login": "Me@x.com"]), allowedLogins: ["me@x.com"]))
        XCTAssertFalse(API.authorized(req(["x-forwarded-for": "100.1.1.1", "tailscale-user-login": "other@x.com"]), allowedLogins: ["me@x.com"]))
    }

    func testOrgAttentionRuleCannotRescueScamContent() {
        var probs = [String: Double](); probs["fraud_impersonation"] = 0.85; probs["account_legit"] = 0.05
        let j = ContentJudgment(categoryProbs: probs, callback: 0.1, fraud: 0.9, specific: 0.2, automated: 0.5)
        XCTAssertEqual(Classifier.decide(context: CallerContext(orgRule: .attention), voicemail: nil, judgment: j).bucket, .scam)
    }
}

final class RemindersRenderTests: XCTestCase {
    func testRenderAttentionReminder() {
        var it = ReviewFixTests().item("call:A")
        it.bucket = .attention; it.category = "appointment"; it.callback = .init(recommended: true, probability: 0.8)
        it.caller = .init(name: "Dana", organization: "Bayview Dental"); it.summary = "Confirming Thursday 3pm."; it.number = "+15550100003"
        let (title, notes, url) = RemindersBridge.render(it)
        XCTAssertEqual(title, "Call back Bayview Dental — Appointment")
        XCTAssertTrue(notes.hasPrefix("Confirming Thursday 3pm."))
        XCTAssertTrue(notes.hasSuffix("ScamShield ref: call:A"))
        XCTAssertEqual(url?.absoluteString, "tel:+15550100003")
    }
}

final class ReminderReconcileTests: XCTestCase {
    typealias O = RemindersBridge.Observed

    func testTickReportedOnceThenStable() {
        var base = ["call:A": "attention|0"]
        let r1 = RemindersBridge.readBack(observed: ["call:A": O(bucket: .attention, done: true)], baselines: base, misses: [:], listsJustCreated: false)
        XCTAssertEqual(r1.changes, [.init(id: "call:A", bucket: nil, done: true)])
        base.merge(r1.baselines) { $1 }
        let r2 = RemindersBridge.readBack(observed: ["call:A": O(bucket: .attention, done: true)], baselines: base, misses: [:], listsJustCreated: false)
        XCTAssertTrue(r2.changes.isEmpty)
    }

    func testMoveIsACorrection() {
        let r = RemindersBridge.readBack(observed: ["call:A": O(bucket: .scam, done: false)], baselines: ["call:A": "review|0"], misses: [:], listsJustCreated: false)
        XCTAssertEqual(r.changes, [.init(id: "call:A", bucket: .scam, done: nil)])
        XCTAssertEqual(r.baselines["call:A"], "scam|0")
    }

    func testDeletionNeedsTwoPassesAndEmptyFetchAfterListCreationIsIgnored() {
        let base = ["call:A": "attention|0", "call:B": "scam|0"]
        let r0 = RemindersBridge.readBack(observed: [:], baselines: base, misses: [:], listsJustCreated: true)
        XCTAssertTrue(r0.changes.isEmpty); XCTAssertTrue(r0.misses.isEmpty)
        let r1 = RemindersBridge.readBack(observed: ["call:B": O(bucket: .scam, done: false)], baselines: base, misses: [:], listsJustCreated: false)
        XCTAssertTrue(r1.changes.isEmpty); XCTAssertEqual(r1.misses["call:A"], .some(1))
        // Reappears → miss counter cleared, nothing archived.
        let back = RemindersBridge.readBack(observed: ["call:A": O(bucket: .attention, done: false)], baselines: base, misses: ["call:A": 1], listsJustCreated: false)
        XCTAssertTrue(back.changes.isEmpty); XCTAssertEqual(back.misses["call:A"], .some(nil))
        // Missing twice → treated as deleted by the user.
        let r2 = RemindersBridge.readBack(observed: ["call:B": O(bucket: .scam, done: false)], baselines: base, misses: ["call:A": 1], listsJustCreated: false)
        XCTAssertEqual(r2.changes, [.init(id: "call:A", bucket: nil, done: true)]); XCTAssertEqual(r2.baselines["call:A"], "deleted")
    }

    func testTombstonedRefsIgnored() {
        let r = RemindersBridge.readBack(observed: [:], baselines: ["call:A": "deleted"], misses: [:], listsJustCreated: false)
        XCTAssertTrue(r.changes.isEmpty)
    }
}

final class RoboKillerTests: XCTestCase {
    // Synthetic page shaped like lookup.robokiller.com/p/<number>.
    func page(status: String, rep: String, reports: Int, calls: Int, category: String?) -> String {
        var s = """
        <div class="status" id="userReputation"> <h3 class="green" > \(rep) </h3> <p>User reputation</p> </div>
        <div class="status" id="roboStatus"> <h3 class="red" > \(status) </h3> <p>Robokiller status</p> </div>
        <div class="analytics-box" id="totalCall"> <h3>\(calls)</h3> </div>
        <div class="analytics-box" id="userReports"> <h3>\(reports)</h3> </div>
        """
        if let category { s += #"<div class="reported-category"> <h3>\#(category)</h3> </div><div class="call-box"> <p> a personal loan up to 71,000 </p></div>"# }
        return s
    }

    func testParsesLoanOffer() throws {
        let r = try XCTUnwrap(RoboKillerLookup.parse(page(status: "Blocked", rep: "Positive", reports: 0, calls: 24, category: "Loan Offer")))
        XCTAssertTrue(r.blocked); XCTAssertEqual(r.category, "Loan Offer"); XCTAssertEqual(r.totalCalls, 24)
        XCTAssertEqual(r.scamCategory, "loan_offer"); XCTAssertEqual(r.transcript, "a personal loan up to 71,000")
    }

    func testCleanNumberIsNoEvidence() throws {
        let r = try XCTUnwrap(RoboKillerLookup.parse(page(status: "Allowed", rep: "Positive", reports: 0, calls: 2, category: nil)))
        XCTAssertNil(r.scamCategory)
        XCTAssertEqual(Classifier.decide(context: CallerContext(onlineReport: r), voicemail: nil, judgment: nil).bucket, .review)
    }

    func testNegativeWithReportsIsSpam() throws {
        let r = try XCTUnwrap(RoboKillerLookup.parse(page(status: "Allowed", rep: "Negative", reports: 2, calls: 18, category: nil)))
        XCTAssertEqual(r.scamCategory, "spam_other")
    }

    func testLegitCategoryNotSpamEvenIfBlocked() {
        XCTAssertNil(OnlineReport(blocked: true, category: "Appointment Reminder").scamCategory)
    }

    func testOnlineReportNeverOverridesContact() {
        let ctx = CallerContext(contactName: "Mom", onlineReport: OnlineReport(blocked: true, category: "Scam"))
        XCTAssertEqual(Classifier.decide(context: ctx, voicemail: nil, judgment: nil).bucket, .attention)
    }

    func testUnrecognizedPageIsNil() { XCTAssertNil(RoboKillerLookup.parse("<html>captcha</html>")) }
}

final class CloudDriveTests: XCTestCase {
    func testPublishAndApplyCorrection() throws {
        let e = try ReviewFixTests().makeEngine()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cloud-\(UUID().uuidString)/ScamShield")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cloud = CloudDriveBridge(store: e.store, root: root, log: { _ in })
        e.cloud = cloud
        var it = ReviewFixTests().item("call:A"); it.done = false; it.userLabeled = false; it.bucket = .review; it.category = "unclear"
        try e.store.save(it, ItemState(callUID: "A", voicemailID: nil, contentKey: "none", judgment: nil, needsModel: false, audioPath: nil))
        e.syncCloudLocked()
        let inbox = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("inbox.json"))) as! [String: Any]
        XCTAssertEqual((inbox["items"] as! [[String: Any]]).first?["id"] as? String, "call:A")
        // iPhone writes a correction → applied once, file removed, inbox republished.
        let corr = #"{"id":"c1","itemId":"call:A","action":"label","bucket":"scam","category":"telemarketing","applyToNumber":false,"at":"2026-11-17T17:41:00Z"}"#
        try corr.write(to: root.appendingPathComponent("corrections/c1.json"), atomically: true, encoding: .utf8)
        e.syncCloudLocked()
        XCTAssertEqual(e.store.item("call:A")?.0.bucket, .scam)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("corrections/c1.json").path))
        let again = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("inbox.json"))) as! [String: Any]
        XCTAssertEqual((again["items"] as! [[String: Any]]).first?["bucket"] as? String, "scam")
        // Same correction id replayed → ignored.
        try e.store.save({ var x = e.store.item("call:A")!.0; x.bucket = .review; return x }(), e.store.item("call:A")!.1)
        try corr.write(to: root.appendingPathComponent("corrections/c1.json"), atomically: true, encoding: .utf8)
        e.syncCloudLocked()
        XCTAssertEqual(e.store.item("call:A")?.0.bucket, .review)
    }
}

final class TrainingTests: XCTestCase {
    // Shapes measured on the user's real voicemails (spread "background" legit mass).
    func probs(legitEach: Double, robocall: Double) -> [String: Double] {
        var p: [String: Double] = [:]
        for k in ["personal", "appointment_or_medical", "delivery_or_service", "work_or_recruiter", "account_legit"] { p[k] = legitEach }
        p["robocall_other"] = robocall; p["loan_or_debt_offer"] = 0.02; p["fraud_impersonation"] = 0.01; p["sales_telemarketing"] = 0.01
        p["silent_or_unclear"] = max(0, 1 - 5 * legitEach - robocall - 0.04)
        return p
    }

    func testTimeSensitivePressTwoRobocallIsScam() {
        // sum legit ≈ 0.24 (above the old 0.20 floor), max legit ≈ 0.09 → now Scams.
        let j = ContentJudgment(categoryProbs: probs(legitEach: 0.048, robocall: 0.65), callback: 0.1, fraud: 0.4, specific: 0.15, automated: 0.8)
        let d = Classifier.decide(context: CallerContext(), voicemail: nil, judgment: j)
        XCTAssertEqual(d.bucket, .scam); XCTAssertEqual(d.category, "robocall")
    }

    func testOneClearlyPlausibleLegitCategoryStillBlocksScam() {
        var p = probs(legitEach: 0.02, robocall: 0.6); p["appointment_or_medical"] = 0.2
        let d = Classifier.decide(context: CallerContext(), voicemail: nil, judgment: ContentJudgment(categoryProbs: p, callback: 0.2, fraud: 0.2, specific: 0.4, automated: 0.6))
        XCTAssertEqual(d.bucket, .review)
    }

    func testSimilarityToLabelledScam() {
        let a = Similarity.shingles("please press two this update is time sensitive and it's important we talk to you immediately")
        let b = Similarity.shingles("Please press 2. This update is time sensitive, and it's important we talk to you immediately to be connected")
        XCTAssertGreaterThan(Similarity.jaccard(a, b), 0.5)
        XCTAssertLessThan(Similarity.jaccard(a, Similarity.shingles("hi this is dana from bayview dental confirming your cleaning")), 0.05)
        var ctx = CallerContext(); ctx.similarLabel = (.scam, 0.8); ctx.similarCategory = "loan_offer"
        let j = ContentJudgment(categoryProbs: probs(legitEach: 0.08, robocall: 0.4), callback: 0.1, fraud: 0.3, specific: 0.2, automated: 0.6)
        let d = Classifier.decide(context: ctx, voicemail: nil, judgment: j)
        XCTAssertEqual(d.bucket, .scam); XCTAssertEqual(d.category, "loan_offer")
    }

    func testSimilarityCannotOverrideClearlyLegitContent() {
        var ctx = CallerContext(); ctx.similarLabel = (.scam, 0.9)
        var p = probs(legitEach: 0.02, robocall: 0.1); p["personal"] = 0.7
        XCTAssertEqual(Classifier.decide(context: ctx, voicemail: nil, judgment: ContentJudgment(categoryProbs: p, callback: 0.6, fraud: 0.05, specific: 0.6, automated: 0.1)).bucket, .attention)
    }
}
