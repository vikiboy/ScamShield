import Foundation

/// Orchestrates: Apple stores → candidates → context + models → policy → store → push.
/// Idempotent: every pass re-reads a window of recent data and only (re)processes items
/// whose content changed, so restarts, late iCloud sync and model outages are all handled
/// by simply running another pass.
public final class Engine: @unchecked Sendable {
    public let config: Config
    public let store: Store
    let sources: AppleSources
    let brain: Brain
    public let context: PersonalContext
    let push: WebPush?
    let log: (String) -> Void
    let queue = DispatchQueue(label: "scamshield.engine")
    public private(set) var lastError: String?
    /// iPhone delivery via Apple Reminders (iCloud). Set before starting.
    public var reminders: RemindersBridge?
    /// Opt-in online lookup for unknown callers who left no message.
    public var robokiller: RoboKillerLookup?
    /// iPhone app sync through iCloud Drive (docs/SYNC.md).
    public var cloud: CloudDriveBridge?
    private var cloudSyncScheduled = false
    private var pendingAlerts = Set<String>()
    private var reminderSyncScheduled = false

    public init(config: Config, store: Store, sources: AppleSources, brain: Brain, context: PersonalContext, push: WebPush?, log: @escaping (String) -> Void) {
        self.config = config; self.store = store; self.sources = sources; self.brain = brain
        self.context = context; self.push = push; self.log = log
    }

    /// Schedules an ingest pass (coalesces bursts of file events).
    private var scheduled = false
    public func scheduleIngest(after delay: TimeInterval = 2) {
        queue.async {
            if self.scheduled { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + delay) { self.scheduled = false; self.ingestNow() }
        }
    }

    public func runOnQueue(_ body: @escaping () -> Void) { queue.async(execute: body) }

    /// Bump when policy/context logic changes; on startup, items are re-decided (cached model
    /// judgments are reused, so this is fast and needs no model calls).
    public static let policyVersion = "7"

    public func reclassifyIfPolicyChanged() {
        queue.async {
            let key = "policy.version|contacts=\(self.context.contactsStatus)|calendar=\(self.context.calendarStatus)"
            let current = "\(Self.policyVersion)|\(key)"
            guard self.store.get("policy.applied") != current else { return }
            // Re-judging needs the models; if they're still loading, try again shortly.
            guard self.brain.health()["decider"] == "ok" else {
                self.log("policy change pending: waiting for the decision model")
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { self.reclassifyIfPolicyChanged() }
                return
            }
            self.ingestNow(full: true)   // re-reads Apple's stores; cached model judgments are reused
            guard self.lastError == nil else { return }   // retry on next start
            self.store.set("policy.applied", current)
            self.log("re-decided items for policy/context change")
        }
    }

    /// Runs one ingest pass synchronously (CLI / tests).
    public func ingestSync() { queue.sync { ingestNow() } }

    /// Reputation data changed: re-decide open, unlabeled items without message content
    /// (content-based items are dominated by the transcript and keep their decision).
    public func reclassifyNoMessageItems() {
        queue.async {
            var n = 0
            for id in self.store.itemIDs(where: "done=0 AND user_labeled=0 AND json_extract(json, '$.voicemail') IS NULL") {
                if let (i, s) = self.store.item(id) {
                    let before = i.bucket
                    self.reprocess(i, s)
                    if self.store.item(id)?.0.bucket != before { n += 1 }
                }
            }
            if n > 0 { self.log("reputation update moved \(n) items") }
        }
    }

    // MARK: Ingest

    func ingestNow(full: Bool = false) {
        let started = Date()
        let firstRun = store.get("ingest.initialized") == nil
        let backfillStart = started.addingTimeInterval(-Double(config.backfillDays) * 86400)
        let watermark = full ? backfillStart : (store.getDate("ingest.watermark") ?? backfillStart)
        do {
            let calls = try sources.readCalls(since: watermark.addingTimeInterval(-3 * 86400))
            try store.recordCalls(calls)
            let vms: [AppleVoicemail]
            do { vms = try sources.readVoicemails(since: watermark.addingTimeInterval(-30 * 86400)) }
            catch { log("voicemail read failed: \(error)"); vms = [] }

            let candidates = dedupe(Self.pairCandidates(calls: calls, voicemails: vms))
            var processed = 0
            for cand in candidates {
                if try process(cand, backfill: firstRun || full, force: full) { processed += 1 }
            }
            if let maxDate = (calls.map(\.date) + vms.map(\.date)).max() { store.setDate("ingest.watermark", max(store.getDate("ingest.watermark") ?? watermark, maxDate)) }
            if let d = calls.filter({ !$0.originated }).map(\.date).max() { store.setDate("status.lastCallSeen", max(store.getDate("status.lastCallSeen") ?? d, d)) }
            if let d = vms.map(\.date).max() { store.setDate("status.lastVoicemailSeen", max(store.getDate("status.lastVoicemailSeen") ?? d, d)) }
            if full {   // drop items for calls that are no longer "missed" under the current rules
                let keep = Set(candidates.map(\.id))
                for c in calls where !keep.contains("call:\(c.uniqueID)") {
                    if let (i, _) = store.item("call:\(c.uniqueID)"), !i.userLabeled { store.delete(i.id) }
                }
            }
            retryModelPending(skip: Set(candidates.map(\.id)))
            retryNotifications()
            syncRemindersLocked()
            syncCloudLocked()
            store.setDate("status.lastIngest", Date())
            store.set("ingest.initialized", "1")
            lastError = nil
            if processed > 0 { log("ingest: \(calls.count) calls, \(vms.count) voicemails read; \(processed) items (re)classified in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
        } catch {
            lastError = "\(error)"
            log("ingest failed: \(error)")
        }
    }

    public struct Candidate: Equatable {
        public var id: String
        public var call: AppleCall?
        public var voicemail: AppleVoicemail?
        public var number: String { call?.number ?? voicemail?.number ?? "" }
        public var date: Date { call?.date ?? voicemail!.date }
    }

    /// Missed incoming calls, each joined to its voicemail (by call UUID, else by number and
    /// a short time window); voicemails with no matching call become standalone candidates.
    public static func pairCandidates(calls: [AppleCall], voicemails: [AppleVoicemail]) -> [Candidate] {
        var byID: [String: Int] = [:]
        var cands: [Candidate] = []
        for c in calls where c.isMissedIncoming {
            byID[c.uniqueID] = cands.count
            cands.append(Candidate(id: "call:\(c.uniqueID)", call: c, voicemail: nil))
        }
        for vm in voicemails {
            if let cu = vm.callUUID, let i = byID[cu] { cands[i].voicemail = vm; continue }
            let key = PhoneNumber.key(vm.number)
            let match = cands.indices.filter { i in
                guard let c = cands[i].call, cands[i].voicemail == nil, !key.isEmpty, PhoneNumber.key(c.number) == key else { return false }
                let dt = vm.date.timeIntervalSince(c.date)
                return dt > -120 && dt < 900
            }.min { abs(vm.date.timeIntervalSince(cands[$0].date)) < abs(vm.date.timeIntervalSince(cands[$1].date)) }
            if let i = match { cands[i].voicemail = vm } else { cands.append(Candidate(id: "vm:\(vm.id)", call: nil, voicemail: vm)) }
        }
        return cands
    }

    /// Prevents duplicates across sync orderings and read windows:
    ///  - a voicemail already attached to an item (e.g. its call fell out of the read window)
    ///    is not re-created as a standalone `vm:` item;
    ///  - a standalone `vm:` item whose call row arrived later is merged into the call item,
    ///    keeping the user's done/label/notified state.
    func dedupe(_ cands: [Candidate]) -> [Candidate] {
        var out: [Candidate] = []
        for c in cands {
            guard let vmID = c.voicemail?.id else { out.append(c); continue }
            let owners = store.itemIDs(where: "json_extract(state, '$.voicemailID') = ?", [vmID])
            if c.id.hasPrefix("vm:") {
                if owners.contains(where: { $0 != c.id }) { continue }   // already attached to a call item
            } else if let standalone = owners.first(where: { $0 == "vm:\(vmID)" }), let (old, _) = store.item(standalone) {
                pendingMerge[c.id] = old
                store.delete(standalone)
            }
            out.append(c)
        }
        return out
    }
    private var pendingMerge: [String: Item] = [:]

    /// Items parked as "still analyzing" whose calls are outside this pass's read window.
    func retryModelPending(skip: Set<String>) {
        let ids = store.itemIDs(where: "json_extract(state, '$.needsModel') = 1").filter { !skip.contains($0) }
        guard !ids.isEmpty, brain.health()["decider"] == "ok" else { return }
        var n = 0
        for id in ids {
            guard let (item, state) = store.item(id), let vm = item.voicemail else { continue }
            let cand = Candidate(id: id,
                call: state.callUID.map { AppleCall(uniqueID: $0, date: item.date, duration: item.durationSec, originated: false, answered: item.answered,
                                                    number: item.number, provider: "", trustScore: state.appleTrust, junkConfidence: state.appleJunkConfidence, name: state.appleName) },
                voicemail: AppleVoicemail(id: vm.id, callUUID: nil, date: item.date, duration: vm.durationSec, number: item.number,
                                          transcript: vm.transcript, transcriptConfidence: vm.transcriptConfidence, audioPath: state.audioPath, isRead: true))
            if (try? process(cand, backfill: true, force: true)) == true { n += 1 }
        }
        log("retried \(n) items that were waiting for the models")
    }

    func retryNotifications() {
        for id in store.itemIDs(where: "bucket='attention' AND done=0 AND notified=0") {
            guard var (item, state) = store.item(id), shouldNotify(item, backfill: false, existing: nil) else { continue }
            if notify(item) { item.notified = true; try? store.save(item, state) }
        }
    }

    /// Includes the prompt fingerprint so changing the model's questions re-judges stored voicemails.
    func contentKey(_ c: Candidate) -> String {
        guard let vm = c.voicemail else { return "none" }
        return "\(vm.id)|\(vm.transcript?.count ?? 0)|\(brain.promptFingerprint)"
    }

    /// Returns true when the item was (re)classified.
    @discardableResult
    func process(_ cand: Candidate, backfill: Bool, force: Bool = false) throws -> Bool {
        var existing = store.item(cand.id)
        if existing == nil, let merged = pendingMerge.removeValue(forKey: cand.id) {
            // Carry the user's state over from the standalone voicemail item.
            let st = ItemState(callUID: nil, voicemailID: cand.voicemail?.id, contentKey: "", judgment: nil, needsModel: false, audioPath: nil)  // same voicemail: not "new"
            existing = (merged, st)
        }
        let key = contentKey(cand)
        if !force, let (_, st) = existing, st.contentKey == key, !st.needsModel { return false }

        var judgment = existing.flatMap { $0.1.contentKey == key ? $0.1.judgment : nil }
        var needsModel = false
        if judgment == nil, let tx = cand.voicemail?.transcript, !tx.isEmpty {
            do { judgment = try brain.judge(transcript: tx) }
            catch { needsModel = true; log("models unavailable, will retry: \(error)") }
        }
        let (item, state) = build(cand, judgment: judgment, needsModel: needsModel, existing: existing, contentKey: key)
        var final = item
        if shouldNotify(final, backfill: backfill, existing: existing?.0) {
            final.notified = notify(final)
        } else if backfill {
            final.notified = true   // never notify for history imported on first run
        }
        try store.save(final, state)
        return true
    }

    func build(_ cand: Candidate, judgment: ContentJudgment?, needsModel: Bool, existing: (Item, ItemState)?, contentKey: String) -> (Item, ItemState) {
        let number = cand.number
        let hist = store.history(number: number, at: cand.date, excluding: cand.call?.uniqueID)
        let rule = store.numberRule(number)
        let contactName = context.contactName(for: number) ?? cand.call?.name
        let trust = cand.call?.trustScore
        var ctx = CallerContext(
            contactName: contactName,
            appleTrustScore: trust,
            appleJunk: [1, 2, 3].contains(trust ?? -1) || (cand.call?.junkConfidence ?? 0) >= 2,
            outgoingCallsTo: hist.outgoing,
            answeredCallsFrom: hist.answeredIncoming,
            callsLast24h: hist.last24h,
            callsLast15m: hist.last15m,
            reputation: store.reputation(number),
            userRule: rule?.0, userRuleCategory: rule?.1,
            orgRule: store.orgRule(judgment?.organization),
            blocked: store.isBlocked(number))
        // Online lookup only when we otherwise know nothing: unknown caller, no message content,
        // no rule/block, recent call. Only the number is sent.
        if let robokiller, config.useRoboKiller, judgment == nil, !ctx.isKnown, rule == nil, !ctx.blocked, !ctx.appleJunk,
           ctx.answeredCallsFrom == 0, Date().timeIntervalSince(cand.date) < 30 * 86400 {
            ctx.onlineReport = robokiller.report(for: number)
        }
        if let tx = cand.voicemail?.transcript, judgment != nil {
            let mine = Similarity.shingles(tx)
            var best: (Bucket, String?, Double)?
            for l in store.labelledTranscripts() {
                let s = Similarity.jaccard(mine, Similarity.shingles(l.text))
                if s > (best?.2 ?? 0) { best = (l.bucket, l.category, s) }
            }
            if let best { ctx.similarLabel = (best.0, best.2); ctx.similarCategory = best.1 }
        }
        if !ctx.isKnown, judgment != nil {
            ctx.calendarMatch = context.calendarMatch(organization: judgment?.organization, callerName: judgment?.callerName, number: number, around: cand.date)
        }
        var decision = Classifier.decide(context: ctx, voicemail: cand.voicemail, judgment: judgment, thresholds: config.thresholds)
        if needsModel {
            decision = Decision(bucket: decision.bucket == .attention ? .attention : .review, category: decision.bucket == .attention ? decision.category : "unclear",
                                confidence: decision.confidence, callbackRecommended: decision.callbackRecommended,
                                callbackProbability: decision.callbackProbability, reasons: ["Still analyzing (models offline)"] + decision.reasons)
        }

        let prev = existing?.0
        let summary = judgment?.summary ?? Self.fallbackSummary(cand, ctx: ctx, decision: decision)
        let rep = ctx.reputation
        var item = Item(
            id: cand.id, number: number, displayNumber: PhoneNumber.display(number), contactName: contactName,
            date: cand.date, answered: cand.call?.connected ?? false, durationSec: cand.call?.duration ?? 0, callCount: hist.last24h,
            voicemail: cand.voicemail.map { .init(id: $0.id, durationSec: $0.duration, transcript: $0.transcript, transcriptConfidence: $0.transcriptConfidence, hasAudio: $0.audioPath != nil) },
            bucket: decision.bucket, category: decision.category, confidence: (decision.confidence * 100).rounded() / 100,
            callback: .init(recommended: decision.callbackRecommended, probability: (decision.callbackProbability * 100).rounded() / 100),
            caller: .init(name: judgment?.callerName, organization: judgment?.organization),
            summary: summary, reasons: decision.reasons,
            reputation: .init(score: (rep.score * 100).rounded() / 100, complaints: rep.complaints, lastReported: rep.lastReported, robocallShare: rep.robocallShare),
            userLabeled: prev?.userLabeled ?? false, done: prev?.done ?? false, notified: prev?.notified ?? false)
        if let prev, let old = existing?.1, old.contentKey != contentKey, cand.voicemail != nil, old.voicemailID != cand.voicemail?.id {
            item.done = false                      // a new voicemail is new information
            reminders?.revive(cand.id)
        }
        if let prev, prev.userLabeled {   // the user's decision is final
            item.bucket = prev.bucket; item.category = prev.category; item.confidence = 1
        }
        let state = ItemState(callUID: cand.call?.uniqueID, voicemailID: cand.voicemail?.id, contentKey: contentKey,
                              judgment: judgment, needsModel: needsModel, audioPath: cand.voicemail?.audioPath,
                              appleTrust: cand.call?.trustScore, appleJunkConfidence: cand.call?.junkConfidence, appleName: cand.call?.name)
        return (item, state)
    }

    static func fallbackSummary(_ c: Candidate, ctx: CallerContext, decision: Decision) -> String {
        let who = ctx.contactName ?? (ctx.isKnown || ctx.answeredCallsFrom > 0 ? "A caller you know" : "An unknown caller")
        if c.voicemail != nil && c.voicemail?.transcript == nil { return "\(who) left a voicemail (no transcript available)." }
        if ctx.callsLast15m >= 2 { return "\(who) called \(ctx.callsLast15m) times in 15 minutes and left no voicemail." }
        if decision.bucket == .scam { return "Missed call from a number with spam reports; no voicemail." }
        if let n = ctx.contactName { return "Missed call from \(n); no voicemail." }
        return ctx.isKnown ? "Missed call from a caller you know; no voicemail." : "Missed call, no voicemail left."
    }

    func shouldNotify(_ item: Item, backfill: Bool, existing: Item?) -> Bool {
        guard !backfill, item.bucket == .attention, !item.notified, !item.done else { return false }
        // iOS already alerts for missed calls from contacts; only add value (a voicemail summary).
        if item.contactName != nil && item.voicemail == nil { return false }
        return Date().timeIntervalSince(item.date) < Double(config.notifyMaxAgeMinutes) * 60
    }

    // MARK: Notifications

    func notify(_ item: Item) -> Bool {
        let title = item.contactName ?? item.caller.organization ?? item.caller.name ?? item.displayNumber
        var body = item.summary
        if item.callback.recommended { body += " · Call back" }
        let pushed = sendPush(["title": title, "body": body, "id": item.id, "url": "/#/item/\(item.id)"]) > 0
        if let reminders, reminders.authorized { pendingAlerts.insert(item.id); return true }
        return pushed
    }

    // MARK: iCloud Drive (iPhone app)

    public func scheduleCloudSync(after delay: TimeInterval = 1) {
        queue.async {
            if self.cloudSyncScheduled { return }
            self.cloudSyncScheduled = true
            self.queue.asyncAfter(deadline: .now() + delay) { self.cloudSyncScheduled = false; self.syncCloudLocked() }
        }
    }

    /// Applies the iPhone's corrections (each exactly once), then republishes the inbox.
    func syncCloudLocked() {
        guard let cloud, cloud.available else { return }
        for (c, file) in cloud.pendingCorrections() {
            if store.get("corr.\(c.id)") == nil {
                switch c.action {
                case "label":
                    if let b = c.bucket.flatMap(Bucket.init) {
                        _ = labelLocked(id: c.itemId, bucket: b, category: c.category, applyToNumber: c.applyToNumber ?? false)
                        log("cloud: iPhone moved \(c.itemId) to \(b.rawValue)")
                    }
                case "done": _ = setDoneLocked(id: c.itemId, done: c.done ?? true)
                case "block":
                    if let n = c.number ?? store.item(c.itemId)?.0.number { setBlockedLocked(number: PhoneNumber.normalize(n), blocked: c.block ?? true) }
                default: log("cloud: unknown correction action \(c.action)")
                }
                store.set("corr.\(c.id)", "1")
            }
            try? FileManager.default.removeItem(at: file)
        }
        let pairs = store.itemsWithState()
        let iso = ISO8601DateFormatter()
        var mac: [String: Any] = [:]
        if let d = store.getDate("status.lastIngest") { mac["lastIngest"] = iso.string(from: d) }
        if let d = store.getDate("status.lastCallSeen") { mac["lastCallSeen"] = iso.string(from: d) }
        if let e = lastError { mac["error"] = e }
        if let p = cloud.uploadProblem() { mac["icloudProblem"] = p; log("cloud: iCloud upload problem: \(p)") }
        mac["models"] = brain.health()   // {"decider": "ok"|"down", "writer": …} → "Classifier: Running" on the phone
        do { try cloud.publish(items: pairs.map(\.0), states: Dictionary(pairs.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a }), mac: mac) }
        catch { log("cloud publish failed: \(error.localizedDescription)") }
    }

    /// Inbox for the direct Wi-Fi path (builds it if this process hasn't published yet).
    public func currentInbox() -> Data? {
        queue.sync {
            if cloud?.lastInbox == nil { syncCloudLocked() }
            return cloud?.lastInbox
        }
    }

    // MARK: Reminders (iPhone)

    /// Debounced; called on EventKit change notifications and after user actions.
    public func scheduleReminderSync(after delay: TimeInterval = 3) {
        queue.async {
            if self.reminderSyncScheduled { return }
            self.reminderSyncScheduled = true
            self.queue.asyncAfter(deadline: .now() + delay) { self.reminderSyncScheduled = false; self.syncRemindersLocked() }
        }
    }

    func syncRemindersLocked() {
        guard let reminders, reminders.authorized else { return }
        do {
            for _ in 0..<3 {
                let changes = try reminders.sync(alertIDs: pendingAlerts, alertLead: TimeInterval(config.reminderAlertLeadSeconds))
                if changes.isEmpty { pendingAlerts.removeAll(); return }
                for ch in changes {
                    if let b = ch.bucket { _ = labelLocked(id: ch.id, bucket: b, category: nil, applyToNumber: false); log("reminders: you moved \(ch.id) to \(b.rawValue)") }
                    if let d = ch.done { _ = setDoneLocked(id: ch.id, done: d) }
                }
            }
        } catch { log("reminders sync failed: \(error.localizedDescription)") }
    }

    @discardableResult
    public func sendPush(_ payload: [String: String]) -> Int {
        guard let push, let data = try? JSONSerialization.data(withJSONObject: payload) else { return 0 }
        var sent = 0
        for json in store.pushSubscriptions() {
            guard let sub = try? JSONDecoder().decode(WebPush.Subscription.self, from: Data(json.utf8)) else { continue }
            switch push.send(data, to: sub) {
            case .sent: sent += 1
            case .gone: store.removePushSubscription(endpoint: sub.endpoint); log("push: subscription expired, removed")
            case .failed(let e): log("push failed: \(e)")
            }
        }
        return sent
    }

    // MARK: User actions (called from the API on the engine queue)

    public func label(id: String, bucket: Bucket, category: String?, applyToNumber: Bool) -> Item? {
        queue.sync { let r = labelLocked(id: id, bucket: bucket, category: category, applyToNumber: applyToNumber); syncRemindersLocked(); syncCloudLocked(); return r }
    }

    func labelLocked(id: String, bucket: Bucket, category: String?, applyToNumber: Bool) -> Item? {
        do {
            guard var (item, state) = store.item(id) else { return nil }
            let modelBucket = item.bucket
            item.bucket = bucket
            item.category = category ?? Self.defaultCategory(bucket)
            item.userLabeled = true
            item.confidence = 1
            store.recordLabel(itemID: id, bucket: bucket, category: category, modelBucket: modelBucket, judgment: state.judgment)
            if let org = item.caller.organization, bucket != .review { store.setOrgRule(org, bucket: bucket) }
            if applyToNumber, !item.number.isEmpty {
                store.setNumberRule(item.number, bucket: bucket, category: category)
                // Re-decide other open items from this number.
                for other in store.itemIDs(where: "number=? AND id!=? AND user_labeled=0", [item.number, id]) {
                    if let (oi, os) = store.item(other) { reprocess(oi, os) }
                }
            }
            state.needsModel = false
            try? store.save(item, state)
            return item
        }
    }

    func reprocess(_ item: Item, _ state: ItemState) {
        var cand = Candidate(id: item.id, call: nil, voicemail: nil)
        if let uid = state.callUID {
            cand.call = AppleCall(uniqueID: uid, date: item.date, duration: item.durationSec, originated: false, answered: item.answered, number: item.number, provider: "",
                                  trustScore: state.appleTrust, junkConfidence: state.appleJunkConfidence, name: state.appleName)
        }
        if let vm = item.voicemail {
            cand.voicemail = AppleVoicemail(id: vm.id, callUUID: nil, date: item.date, duration: vm.durationSec, number: item.number,
                                            transcript: vm.transcript, transcriptConfidence: vm.transcriptConfidence, audioPath: state.audioPath, isRead: true)
        }
        let (ni, ns) = build(cand, judgment: state.judgment, needsModel: state.needsModel, existing: (item, state), contentKey: state.contentKey)
        try? store.save(ni, ns)
    }

    static func defaultCategory(_ b: Bucket) -> String {
        switch b { case .attention: return "callback_request"; case .review: return "unclear"; case .scam: return "spam_other" }
    }

    public func setDone(id: String, done: Bool) -> Item? {
        queue.sync { let r = setDoneLocked(id: id, done: done); syncRemindersLocked(); syncCloudLocked(); return r }
    }

    func setDoneLocked(id: String, done: Bool) -> Item? {
        guard var (item, state) = store.item(id) else { return nil }
        item.done = done
        try? store.save(item, state)
        return item
    }

    public func bulkDone(bucket: Bucket) -> Int {
        queue.sync {
            var n = 0
            for id in store.itemIDs(where: "bucket=? AND done=0", [bucket.rawValue]) {
                if var (item, state) = store.item(id) { item.done = true; try? store.save(item, state); n += 1 }
            }
            syncRemindersLocked()
            syncCloudLocked()
            return n
        }
    }

    public func setBlocked(number: String, blocked: Bool) {
        queue.sync { setBlockedLocked(number: number, blocked: blocked); syncRemindersLocked(); syncCloudLocked() }
    }

    func setBlockedLocked(number: String, blocked: Bool) {
        store.setBlocked(number, blocked)
        for id in store.itemIDs(where: "number=? AND user_labeled=0", [PhoneNumber.normalize(number)]) {
            if let (i, s) = store.item(id) { reprocess(i, s) }
        }
    }

    public func audioPath(voicemailID: String) -> String? {
        let ids = store.itemIDs(where: "json LIKE ?", ["%\"id\":\"\(voicemailID)\"%"])
        for id in ids { if let p = store.item(id)?.1.audioPath, FileManager.default.isReadableFile(atPath: p) { return p } }
        return nil
    }
}
