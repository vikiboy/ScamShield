import Foundation
import EventKit

/// Delivers ScamShield to the iPhone through Apple Reminders (synced by the user's own iCloud).
///
///  - "ScamShield"          Needs Attention — new items get an alert (the iPhone notification).
///  - "ScamShield · Review" uncertain items, silent.
///  - "ScamShield · Scams"  filed spam, silent.
///
/// Two-way: completing a reminder marks the item done; moving it to another ScamShield list is a
/// correction (same as "Move to…"); deleting it marks the item done. Each reminder carries a
/// "ScamShield ref:" line in its notes, which is how we find it again (identifiers can change
/// across iCloud syncs; the notes travel with the reminder).
public final class RemindersBridge {
    public static let listTitles: [Bucket: String] = [.attention: "ScamShield", .review: "ScamShield · Review", .scam: "ScamShield · Scams"]
    static let refPrefix = "ScamShield ref: "

    let ek = EKEventStore()
    let store: Store
    let log: (String) -> Void
    /// Only mirror items this recent (keeps the lists short).
    let windowDays: Double
    public private(set) var status = "unknown"

    public init(store: Store, windowDays: Double = 14, log: @escaping (String) -> Void) {
        self.store = store; self.windowDays = windowDays; self.log = log
    }

    public var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    public func requestAccess() {
        let sem = DispatchSemaphore(value: 0)
        ek.requestFullAccessToReminders { ok, err in
            if let err { self.log("reminders access: \(err.localizedDescription)") }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 120)
        status = authorized ? "granted" : "denied"
    }

    public func refreshStatus() { status = authorized ? "granted" : "denied" }

    // MARK: lists

    public enum BridgeError: Error, LocalizedError {
        case noICloud, fetchFailed
        public var errorDescription: String? {
            switch self {
            case .noICloud: return "No iCloud Reminders account on this Mac (System Settings → Apple Account → iCloud → Reminders)"
            case .fetchFailed: return "Reading Reminders timed out"
            }
        }
    }

    /// Lists live in the iCloud account only (never a work Exchange/Google account), so they
    /// sync to the iPhone via the user's own iCloud.
    func lists() throws -> (lists: [Bucket: EKCalendar], created: Bool) {
        // Only accounts that actually hold reminder lists qualify (iCloud can appear as several
        // EventKit sources; the events one rejects reminder lists).
        let reminderSources = ek.sources.filter { !$0.calendars(for: .reminder).isEmpty }
        let isICloud: (EKSource) -> Bool = { $0.title.lowercased().contains("icloud") }
        guard let source = reminderSources.first(where: { isICloud($0) && $0.sourceType == .calDAV })
                ?? reminderSources.first(where: isICloud)
                ?? ek.defaultCalendarForNewReminders().map(\.source).flatMap({ isICloud($0) ? $0 : nil }) else {
            let all = ek.sources.map { "\($0.title) [type \($0.sourceType.rawValue), \($0.calendars(for: .reminder).count) reminder lists]" }
            log("reminders: no iCloud reminders account; sources: \(all.joined(separator: ", "))")
            throw BridgeError.noICloud
        }
        let existing = ek.calendars(for: .reminder).filter { $0.source.sourceIdentifier == source.sourceIdentifier }
        var out: [Bucket: EKCalendar] = [:], created = false
        for (bucket, title) in Self.listTitles {
            if let cal = existing.first(where: { $0.title == title }) { out[bucket] = cal; continue }
            let cal = EKCalendar(for: .reminder, eventStore: ek)
            cal.title = title
            cal.source = source
            cal.cgColor = bucket == .attention ? CGColor(red: 0, green: 0.48, blue: 1, alpha: 1)
                : bucket == .review ? CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1) : CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
            try ek.saveCalendar(cal, commit: true)
            log("reminders: created list \"\(title)\" in account \"\(source.title)\"")
            out[bucket] = cal; created = true
        }
        return (out, created)
    }

    func fetch(_ cals: [EKCalendar]) throws -> [EKReminder] {
        let sem = DispatchSemaphore(value: 0)
        var out: [EKReminder]?
        ek.fetchReminders(matching: ek.predicateForReminders(in: cals)) { r in out = r; sem.signal() }
        guard sem.wait(timeout: .now() + 30) == .success, let out else { throw BridgeError.fetchFailed }
        return out
    }

    static func ref(of r: EKReminder) -> String? {
        guard let notes = r.notes, let line = notes.components(separatedBy: "\n").last(where: { $0.hasPrefix(refPrefix) }) else { return nil }
        return String(line.dropFirst(refPrefix.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: reconciliation (pure, unit-tested)

    public struct UserChange: Equatable { public var id: String; public var bucket: Bucket?; public var done: Bool? }
    public struct Observed: Equatable { public var bucket: Bucket?; public var done: Bool
        public init(bucket: Bucket?, done: Bool) { self.bucket = bucket; self.done = done } }

    /// Compares what is in Reminders now with what we last wrote ("bucket|done" baselines).
    /// - Differences are user edits; the baseline advances to the observed state so each edit
    ///   is reported exactly once.
    /// - A reminder we wrote that is missing counts as deleted only after two consecutive passes
    ///   (and never on a pass where lists were just created), so a sync hiccup can't archive items.
    public static func readBack(observed: [String: Observed], baselines: [String: String], misses: [String: Int], listsJustCreated: Bool)
        -> (changes: [UserChange], baselines: [String: String], misses: [String: Int?]) {
        var changes: [UserChange] = [], newBase: [String: String] = [:], newMiss: [String: Int?] = [:]
        for (ref, base) in baselines where base != "deleted" {
            let parts = base.split(separator: "|").map(String.init)
            let lastBucket = Bucket(rawValue: parts.first ?? ""), lastDone = parts.count > 1 && parts[1] == "1"
            if let obs = observed[ref] {
                if misses[ref] != nil { newMiss[ref] = .some(nil) }
                var ch = UserChange(id: ref, bucket: nil, done: nil)
                if let b = obs.bucket, b != lastBucket { ch.bucket = b }
                if obs.done != lastDone { ch.done = obs.done }
                if ch.bucket != nil || ch.done != nil {
                    changes.append(ch)
                    newBase[ref] = "\((obs.bucket ?? lastBucket)?.rawValue ?? "")|\(obs.done ? "1" : "0")"
                }
            } else if !listsJustCreated {
                let n = (misses[ref] ?? 0) + 1
                if n >= 2 {
                    changes.append(UserChange(id: ref, bucket: nil, done: true))
                    newBase[ref] = "deleted"; newMiss[ref] = .some(nil)
                } else { newMiss[ref] = .some(n) }
            }
        }
        return (changes, newBase, newMiss)
    }

    // MARK: sync

    /// One reconciliation pass. Returns the user's edits made in Reminders (the engine applies
    /// them, then calls again). `alertIDs` are items that should alert now.
    public func sync(alertIDs: Set<String>, alertLead: TimeInterval) throws -> [UserChange] {
        guard authorized else { return [] }
        let (cals, created) = try lists()
        let bucketOfCal = Dictionary(uniqueKeysWithValues: cals.map { ($0.value.calendarIdentifier, $0.key) })
        var byRef: [String: EKReminder] = [:]
        for r in try fetch(Array(cals.values)) { if let ref = Self.ref(of: r) { byRef[ref] = r } }

        // 1. Read back the user's edits.
        let rb = Self.readBack(observed: byRef.mapValues { Observed(bucket: bucketOfCal[$0.calendar.calendarIdentifier], done: $0.isCompleted) },
                               baselines: store.kvMap(prefix: "rem."), misses: store.kvMap(prefix: "remmiss.").compactMapValues(Int.init),
                               listsJustCreated: created)
        for (k, v) in rb.baselines { store.set("rem.\(k)", v) }
        for (k, v) in rb.misses { store.set("remmiss.\(k)", v.map(String.init)) }
        if !rb.changes.isEmpty { return rb.changes }

        // 2. Write our state; baselines are recorded only after a successful commit.
        let cutoff = Date().addingTimeInterval(-windowDays * 86400)
        var pending: [String: String] = [:]
        for item in store.items(bucket: nil, includeDone: true, limit: 2000) {
            let base = store.get("rem.\(item.id)")
            if base == "deleted" { continue }
            let existing = byRef[item.id]
            if existing == nil {
                if base != nil { continue }   // missing once: wait for the next pass before deciding
                guard item.date >= cutoff || alertIDs.contains(item.id), !item.done else { continue }
            }
            let r = existing ?? EKReminder(eventStore: ek)
            let cal = cals[item.bucket]!
            var changed = existing == nil
            if r.calendar?.calendarIdentifier != cal.calendarIdentifier { r.calendar = cal; changed = true }
            if r.isCompleted != item.done { r.isCompleted = item.done; changed = true }
            let (title, notes, url) = Self.render(item)
            if r.title != title { r.title = title; changed = true }
            if r.notes != notes { r.notes = notes; changed = true }
            if r.url != url { r.url = url; changed = true }
            let prio = item.bucket == .attention ? 1 : 0
            if r.priority != prio { r.priority = prio; changed = true }
            if alertIDs.contains(item.id) && !item.done {
                r.alarms?.forEach { r.removeAlarm($0) }
                r.addAlarm(EKAlarm(absoluteDate: Date().addingTimeInterval(alertLead)))
                changed = true
            }
            if changed { try ek.save(r, commit: false) }
            let want = "\(item.bucket.rawValue)|\(item.done ? "1" : "0")"
            if base != want || changed { pending[item.id] = want }
        }
        if !pending.isEmpty {
            try ek.commit()
            for (k, v) in pending { store.set("rem.\(k)", v) }
        }
        return []
    }

    /// Clears the "deleted" tombstone so a reminder is created again (e.g. a voicemail arrived later).
    public func revive(_ id: String) {
        if store.get("rem.\(id)") == "deleted" { store.set("rem.\(id)", nil) }
    }

    /// Removes the lists ScamShield created (used when switching delivery to the iPhone app).
    public func removeLists() throws -> Int {
        guard authorized else { return 0 }
        var n = 0
        for cal in ek.calendars(for: .reminder) where Self.listTitles.values.contains(cal.title) {
            try ek.removeCalendar(cal, commit: true); n += 1
        }
        for k in store.kvMap(prefix: "rem.").keys { store.set("rem.\(k)", nil) }
        for k in store.kvMap(prefix: "remmiss.").keys { store.set("remmiss.\(k)", nil) }
        return n
    }

    /// Loopback-only diagnostic: a reminder with an alert, to verify iPhone notifications.
    public func sendTestAlert(lead: TimeInterval) throws {
        let (cals, _) = try lists()
        let r = EKReminder(eventStore: ek)
        r.calendar = cals[.attention]
        r.title = "ScamShield test — you can tick this off"
        r.notes = "If your iPhone showed an alert for this, ScamShield notifications work.\n" + Self.refPrefix + "test:\(Int(Date().timeIntervalSince1970))"
        r.addAlarm(EKAlarm(absoluteDate: Date().addingTimeInterval(lead)))
        try ek.save(r, commit: true)
    }

    static let categoryNames: [String: String] = [
        "personal": "Personal", "known_contact": "Someone you know", "appointment": "Appointment", "medical": "Medical",
        "delivery": "Delivery", "recruiter": "Work / recruiter", "business": "Account", "financial_legit": "Account",
        "callback_request": "Callback", "repeated_caller": "Called repeatedly", "no_message": "No message", "unclear": "Unclear",
        "fraud": "Fraud", "robocall": "Robocall", "loan_offer": "Loan offer", "telemarketing": "Telemarketing",
        "spam_other": "Spam", "blocked": "Blocked",
    ]

    static func render(_ item: Item) -> (String, String, URL?) {
        let isPhone = !item.number.contains("@") && !item.number.isEmpty
        let who = item.contactName ?? item.caller.organization ?? item.caller.name ?? (item.number.isEmpty ? "No Caller ID" : item.displayNumber)
        let cat = categoryNames[item.category] ?? item.category
        let title = item.bucket == .attention && item.callback.recommended ? "Call back \(who) — \(cat)" : "\(who) — \(cat)"
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var lines = [item.summary, "", "\(df.string(from: item.date)) · \(item.displayNumber)"]
        if !item.reasons.isEmpty { lines.append("Why: " + item.reasons.joined(separator: "; ")) }
        if let t = item.voicemail?.transcript, !t.isEmpty { lines += ["", "Voicemail: \u{201C}\(t)\u{201D}"] }
        lines += ["", "Move this reminder to another ScamShield list to correct it; tick it when handled.", refPrefix + item.id]
        let url: URL? = isPhone ? URL(string: "tel:\(item.number)") : (item.number.contains("@") ? URL(string: "facetime-audio:\(item.number)") : nil)
        return (title, lines.joined(separator: "\n"), url)
    }
}
