import Foundation
import os

/// What the app keeps on this iPhone: the last good inbox.json (so launch is instant and works
/// offline), pending corrections, and small notification/blocking bookkeeping.
@MainActor
struct LocalState {
    let directory: URL
    let defaults: UserDefaults

    private static let log = Logger(subsystem: "local.scamshield", category: "local")

    static let standard = LocalState(
        directory: URL.applicationSupportDirectory.appending(path: "ScamShield", directoryHint: .isDirectory),
        defaults: .standard)

    static var audioCache: URL {
        URL.cachesDirectory.appending(path: "Voicemail", directoryHint: .isDirectory)
    }

    private var inboxURL: URL { directory.appending(path: "inbox-cache.json") }
    private var pendingURL: URL { directory.appending(path: "pending-corrections.json") }

    // MARK: files

    func cachedInbox() -> (inbox: Inbox, data: Data)? {
        guard let data = try? Data(contentsOf: inboxURL) else { return nil }
        do {
            return (try Inbox.decode(data), data)
        } catch {
            Self.log.error("Ignoring unreadable inbox cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveInbox(_ data: Data) {
        write(data, to: inboxURL)
    }

    func pending() -> [PendingCorrection] {
        guard let data = try? Data(contentsOf: pendingURL) else { return [] }
        return (try? JSON.decoder.decode([PendingCorrection].self, from: data)) ?? []
    }

    func savePending(_ pending: [PendingCorrection]) {
        guard let data = try? JSON.encoder.encode(pending) else { return }
        write(data, to: pendingURL)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("Couldn't save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: defaults

    /// Item ids already notified on this phone, with when.
    var notifiedLedger: [String: Date] {
        get { (defaults.dictionary(forKey: "notifiedLedger") as? [String: Date]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: "notifiedLedger") }
    }

    /// Set after the first successful load, when every existing item is marked as notified.
    var notificationsSeeded: Bool {
        get { defaults.bool(forKey: "notificationsSeeded") }
        nonmutating set { defaults.set(newValue, forKey: "notificationsSeeded") }
    }

    var askedForNotifications: Bool {
        get { defaults.bool(forKey: "askedForNotifications") }
        nonmutating set { defaults.set(newValue, forKey: "askedForNotifications") }
    }

    /// Numbers blocked from this phone. inbox.json has no blocklist, so this is the app's own memory.
    var blockedNumbers: Set<String> {
        get { Set(defaults.stringArray(forKey: "blockedNumbers") ?? []) }
        nonmutating set { defaults.set(Array(newValue).sorted(), forKey: "blockedNumbers") }
    }

    var lastChecked: Date? {
        get { defaults.object(forKey: "lastChecked") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "lastChecked") }
    }

    func resetForNewFolder() {
        notificationsSeeded = false
        notifiedLedger = [:]
        lastChecked = nil
        try? FileManager.default.removeItem(at: inboxURL)
        try? FileManager.default.removeItem(at: pendingURL)
    }
}
