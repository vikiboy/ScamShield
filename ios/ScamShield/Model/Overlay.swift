import Foundation

/// A correction the app has made but the Mac has not reflected in inbox.json yet.
struct PendingCorrection: Codable, Hashable, Sendable {
    var correction: Correction
    /// False while the file could not be written to the sync folder (it is retried on refresh).
    var written: Bool
}

/// Optimistic state: the app shows its own pending corrections on top of the last inbox.json
/// until a newer inbox reflects them (docs/SYNC.md). Pure functions, no I/O.
enum Overlay {
    /// How long after a correction the Mac gets to reflect it before the app stops overlaying it.
    static let grace: TimeInterval = 120

    /// Adds a correction, dropping older pending ones it supersedes (same item and action, or for
    /// blocks the same number). Without this, Done followed by Undo would leave the older "done"
    /// overlay in place once the Undo matched the inbox and was pruned.
    static func adding(_ correction: Correction, to pending: [PendingCorrection], written: Bool) -> [PendingCorrection] {
        pending.filter { !supersedes(correction, $0.correction) }
            + [PendingCorrection(correction: correction, written: written)]
    }

    static func supersedes(_ newer: Correction, _ older: Correction) -> Bool {
        guard newer.action == older.action else { return false }
        if newer.action == .block { return newer.number == older.number }
        return newer.itemId == older.itemId
    }

    /// Applies pending corrections, oldest first, to the inbox items.
    static func apply(_ pending: [PendingCorrection], to items: [Item]) -> [Item] {
        guard !pending.isEmpty else { return items }
        let byItem = Dictionary(grouping: pending.map(\.correction), by: \.itemId)
        return items.map { item in
            guard let corrections = byItem[item.id] else { return item }
            return corrections.sorted { $0.at < $1.at }.reduce(item, apply)
        }
    }

    static func apply(_ item: Item, _ correction: Correction) -> Item {
        var item = item
        switch correction.action {
        case .done:
            if let done = correction.done { item.done = done }
        case .label:
            if let bucket = correction.bucket {
                item.bucket = bucket
                item.category = correction.category ?? bucket.defaultCategory
                item.userLabeled = true
            }
        case .block:
            break  // Blocking only affects future calls; the Mac decides how to file this one.
        }
        return item
    }

    /// Whether the inbox's copy of the item already shows the correction.
    static func isReflected(_ correction: Correction, in item: Item) -> Bool {
        switch correction.action {
        case .done:
            return correction.done == item.done
        case .label:
            return correction.bucket == item.bucket && (correction.category ?? item.category) == item.category
        case .block:
            return false  // inbox.json carries no blocklist; only the time rule can retire a block.
        }
    }

    /// Drops pending corrections the given inbox has caught up with: the inbox was generated more
    /// than `grace` after the correction, or the item already matches. Unwritten corrections are
    /// kept until they reach the folder.
    static func prune(_ pending: [PendingCorrection], against inbox: Inbox) -> [PendingCorrection] {
        let items = Dictionary(inbox.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pending.filter { entry in
            guard entry.written else { return true }
            let correction = entry.correction
            if let generated = inbox.generatedAt, generated > correction.at.addingTimeInterval(grace) {
                return false
            }
            if let item = items[correction.itemId], isReflected(correction, in: item) {
                return false
            }
            return true
        }
    }
}

/// Which calls deserve a local notification (docs/SYNC.md § Notifications). Pure, takes `now`.
enum NotificationPlanner {
    static let window: TimeInterval = 24 * 60 * 60

    /// Attention items that are open, from the last 24 h, and not yet notified on this phone.
    /// Review and Scams never notify.
    static func itemsToNotify(_ items: [Item], notified: Set<String>, now: Date) -> [Item] {
        items.filter { item in
            guard item.bucket == .attention, !item.done, !notified.contains(item.id),
                  let date = item.date else { return false }
            return date > now.addingTimeInterval(-window)
        }
    }

    static func title(for item: Item) -> String { item.title }

    static func body(for item: Item) -> String {
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (summary?.isEmpty == false ? summary : nil)
            ?? (item.voicemail != nil ? "Left a voicemail" : "Missed call")
        return item.callbackRecommended ? base + " · Call back" : base
    }

    /// How long an id is remembered after it was notified. Anything older is outside the 24 h
    /// window anyway, so forgetting it cannot cause a repeat alert.
    static let memory: TimeInterval = 7 * 24 * 60 * 60

    /// Notified ids with the time they were recorded, minus entries past `memory`.
    static func trimmed(_ ledger: [String: Date], now: Date) -> [String: Date] {
        ledger.filter { $0.value > now.addingTimeInterval(-memory) }
    }
}
