import Foundation
import Observation
import os

/// A short message shown above the tab bar, optionally with Undo.
struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: (@MainActor () -> Void)?
}

/// App state: the picked folder, the last inbox.json, pending corrections overlaid on it, and
/// the refresh/notification cycle.
@Observable
@MainActor
final class InboxStore {
    static let shared = InboxStore()

    enum Phase: Equatable {
        /// No usable folder: show onboarding, with an explanation when access was lost.
        case needsFolder(message: String?)
        case ready
    }

    private(set) var phase: Phase
    private(set) var folder: SyncFolder?
    private(set) var folderSource: FolderAccess.Source?
    private(set) var inbox: Inbox?
    /// Inbox items with pending corrections applied; what every screen shows.
    private(set) var items: [Item] = []
    private(set) var problem: SyncError?
    private(set) var isRefreshing = false
    private(set) var lastChecked: Date?
    private(set) var blockedNumbers: Set<String>
    private(set) var unsyncedCount = 0
    var toast: Toast?

    private var pending: [PendingCorrection]
    private var refreshTask: Task<Void, Never>?
    private let local: LocalState
    private static let log = Logger(subsystem: "local.scamshield", category: "store")

    init(local: LocalState = .standard) {
        self.local = local
        #if DEBUG
        // `-ScamShieldResetLocalState YES`: start UI tests and screenshots from a clean phone.
        if local.defaults.bool(forKey: "ScamShieldResetLocalState") {
            local.resetForNewFolder()
            local.blockedNumbers = []
        }
        #endif
        pending = local.pending()
        blockedNumbers = local.blockedNumbers
        lastChecked = local.lastChecked
        switch FolderAccess.resolve(defaults: local.defaults) {
        case .resolved(let url, let source):
            folder = SyncFolder(url: url)
            folderSource = source
            phase = .ready
        case .notChosen:
            phase = .needsFolder(message: nil)
        case .failed(let message):
            phase = .needsFolder(message: message)
        }
        if phase == .ready, let cached = local.cachedInbox() {
            inbox = cached.inbox
        }
        recompute()
    }

    // MARK: queries

    func item(withID id: String) -> Item? {
        items.first { $0.id == id }
    }

    func openItems(in bucket: Bucket) -> [Item] {
        items.filter { $0.bucket == bucket && !$0.done }
    }

    func openCount(_ bucket: Bucket) -> Int {
        items.reduce(0) { $0 + ($1.bucket == bucket && !$1.done ? 1 : 0) }
    }

    func isBlocked(_ item: Item) -> Bool {
        blockedNumbers.contains(item.number) || item.category == "blocked"
    }

    var hasLoaded: Bool { inbox != nil }

    // MARK: folder

    /// Called with the folder the user picked during onboarding or from Settings.
    func useFolder(_ url: URL) throws {
        try FolderAccess.save(url, defaults: local.defaults)
        let changed = folder?.url.standardizedFileURL != url.standardizedFileURL
        if changed {
            local.resetForNewFolder()
            inbox = nil
            pending = []
            lastChecked = nil
        }
        folder = SyncFolder(url: url)
        folderSource = .bookmark
        problem = nil
        phase = .ready
        recompute()
        let askNotifications = !local.askedForNotifications
        Task {
            if askNotifications {
                local.askedForNotifications = true
                await Notifier.requestAuthorization()
            }
            await refresh()
        }
    }

    // MARK: refresh

    /// Re-reads inbox.json. Concurrent callers share one read.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard phase == .ready, let folder else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await flushUnwritten(to: folder)

        do {
            // Same Wi-Fi as the Mac? Get the inbox directly (instant, no iCloud involved).
            let direct = await MacLink.fetchInbox()
            let (fresh, data) = try await offMain {
                let data = try direct ?? folder.readInbox()
                do {
                    return (try Inbox.decode(data), data)
                } catch {
                    throw SyncError.inboxMalformed(Self.describe(error))
                }
            }
            lastChecked = .now
            local.lastChecked = lastChecked
            problem = nil
            // iCloud can briefly hand back an older copy; never go backwards.
            if let current = inbox?.generatedAt, let incoming = fresh.generatedAt, incoming < current {
                Self.log.notice("Ignoring older inbox.json from \(incoming, privacy: .public)")
            } else {
                inbox = fresh
                local.saveInbox(data)
                pending = Overlay.prune(pending, against: fresh)
                local.savePending(pending)
                recompute()
            }
            await notifyNewItems()
        } catch let error as SyncError {
            Self.log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            problem = error
        } catch {
            problem = .io(error.localizedDescription)
        }
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context),
             .keyNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return "invalid JSON"
        }
    }

    /// Posts local notifications for new Attention calls (never Review or Scams). The first
    /// successful load marks everything as already seen so setup doesn't flood the phone.
    private func notifyNewItems() async {
        let now = Date.now
        var ledger = NotificationPlanner.trimmed(local.notifiedLedger, now: now)
        if !local.notificationsSeeded {
            for item in items { ledger[item.id] = now }
            local.notificationsSeeded = true
        } else {
            let due = NotificationPlanner.itemsToNotify(items, notified: Set(ledger.keys), now: now)
            if !due.isEmpty {
                await Notifier.post(due)
                for item in due { ledger[item.id] = now }
            }
        }
        local.notifiedLedger = ledger
        await Notifier.setBadge(openCount(.attention))
    }

    // MARK: actions

    func setDone(_ ids: [String], done: Bool, message: String? = nil) {
        guard !ids.isEmpty else { return }
        for id in ids { record(.done(itemId: id, done: done)) }
        let text = message ?? (done ? "Marked as done" : "Moved back to open")
        toast = Toast(message: text) { [weak self] in
            self?.setDone(ids, done: !done, message: done ? "Moved back to open" : "Marked as done")
        }
    }

    func move(_ item: Item, to bucket: Bucket, category: String, applyToNumber: Bool) {
        record(.label(itemId: item.id, bucket: bucket, category: category, applyToNumber: applyToNumber))
        toast = Toast(message: "Moved to \(bucket.title) · \(Category.label(category))")
    }

    func setBlocked(_ item: Item, block: Bool) {
        guard item.hasPhoneNumber else { return }
        record(.block(itemId: item.id, number: item.number, block: block))
        if block { blockedNumbers.insert(item.number) } else { blockedNumbers.remove(item.number) }
        local.blockedNumbers = blockedNumbers
        toast = Toast(message: block ? "Number blocked" : "Number unblocked")
    }

    /// "Seen": marks every open Needs Attention call done (undoable from the toast).
    func markAllAttentionSeen() {
        let ids = openItems(in: .attention).map(\.id)
        setDone(ids, done: true, message: "Marked \(ids.count) \(ids.count == 1 ? "call" : "calls") as seen")
    }

    /// Writes a done correction for every open scam call.
    func archiveAllScams() {
        let ids = openItems(in: .scam).map(\.id)
        setDone(ids, done: true, message: "Archived \(ids.count) \(ids.count == 1 ? "call" : "calls")")
    }

    /// Applies a correction locally at once, then writes it to the folder in the background.
    private func record(_ correction: Correction) {
        pending = Overlay.adding(correction, to: pending, written: false)
        local.savePending(pending)
        recompute()
        guard let folder else { return }
        Task { await write(correction, to: folder) }
    }

    private func write(_ correction: Correction, to folder: SyncFolder) async {
        do {
            try await offMain { try folder.write(correction) }
            if let index = pending.firstIndex(where: { $0.correction.id == correction.id }) {
                pending[index].written = true
                local.savePending(pending)
            }
        } catch {
            Self.log.error("Correction not written yet: \(error.localizedDescription, privacy: .public)")
            toast = Toast(message: "Saved on this iPhone. It will reach your Mac once iCloud Drive is available.")
        }
        recompute()
    }

    /// Retries corrections that couldn't be written earlier (e.g. offline).
    private func flushUnwritten(to folder: SyncFolder) async {
        for entry in pending where !entry.written {
            let correction = entry.correction
            guard (try? await offMain({ try folder.write(correction) })) != nil else { return }
            if let index = pending.firstIndex(where: { $0.correction.id == correction.id }) {
                pending[index].written = true
            }
        }
        local.savePending(pending)
    }

    private func recompute() {
        items = Overlay.apply(pending, to: inbox?.items ?? [])
        unsyncedCount = pending.filter { !$0.written }.count
    }
}
