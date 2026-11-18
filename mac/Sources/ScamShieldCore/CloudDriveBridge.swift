import Foundation
import CryptoKit

/// iPhone sync through the user's iCloud Drive (see docs/SYNC.md). Works with a free Apple ID:
/// no CloudKit/entitlements — the iPhone app opens the folder via a user-picked bookmark.
public final class CloudDriveBridge {
    public let root: URL
    let store: Store
    let log: (String) -> Void
    /// Done items stay in the inbox this long; voicemail audio is copied for items this recent.
    let doneWindow: TimeInterval = 30 * 86400
    let audioWindow: TimeInterval = 30 * 86400

    public init(store: Store, root: URL? = nil, log: @escaping (String) -> Void) {
        self.store = store; self.log = log
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ScamShield", isDirectory: true)
    }

    var corrections: URL { root.appendingPathComponent("corrections", isDirectory: true) }
    var audio: URL { root.appendingPathComponent("audio", isDirectory: true) }

    /// Latest inbox JSON (also served directly to the iPhone over Wi-Fi).
    public private(set) var lastInbox: Data?

    /// iCloud's own upload status for inbox.json; non-nil means the iPhone can't get updates via iCloud.
    public func uploadProblem() -> String? {
        var u = root.appendingPathComponent("inbox.json")
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey]) else { return nil }
        return v.ubiquitousItemUploadingError?.localizedDescription
    }

    public var available: Bool {
        FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path)
    }

    func ensureFolders() throws {
        let fm = FileManager.default
        for d in [root, corrections, audio] where !fm.fileExists(atPath: d.path) {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let readme = root.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            try "This folder is managed by ScamShield (Mac ↔ iPhone sync). Please don't edit or move it.\n"
                .write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    // MARK: corrections (iPhone → Mac)

    public struct Correction: Decodable, Equatable {
        public var id: String
        public var itemId: String
        public var action: String
        public var bucket: String?
        public var category: String?
        public var applyToNumber: Bool?
        public var done: Bool?
        public var number: String?
        public var block: Bool?
        public var at: String?
    }

    /// Pending corrections with their files, oldest first. Unreadable files are left for the next pass.
    public func pendingCorrections() -> [(Correction, URL)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: corrections, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var patience: TimeInterval = 10   // after one timeout, don't stall the pass on the rest
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .compactMap { url in
                // With "Optimize Mac Storage", iCloud keeps files the iPhone wrote as online-only
                // placeholders; a background process must request the download and read through
                // a file coordinator. Not-yet-downloaded files are retried on the next pass.
                guard let data = Self.readDownloading(url, timeout: patience) else {
                    patience = 0
                    log("cloud: waiting for iCloud to download \(url.lastPathComponent)")
                    return nil
                }
                guard let c = try? JSONDecoder().decode(Correction.self, from: data) else {
                    log("cloud: ignoring malformed correction \(url.lastPathComponent)")
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return (c, url)
            }
            // Apply in the order the user acted (ISO-8601 strings sort chronologically).
            .sorted { ($0.0.at ?? "") < ($1.0.at ?? "") }
    }

    static func readDownloading(_ url: URL, timeout: TimeInterval = 10) -> Data? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var data: Data?
        var err: NSError?
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in data = try? Data(contentsOf: u) }
            if let d = data, !d.isEmpty { return d }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    // MARK: inbox (Mac → iPhone)

    /// Writes inbox.json (atomic) and copies recent voicemail audio. Skips the write when nothing changed.
    public func publish(items: [Item], states: [String: ItemState], mac: [String: Any]) throws {
        try ensureFolders()
        let now = Date()
        let fm = FileManager.default
        var wantedAudio = Set<String>()
        var out: [[String: Any]] = []
        for item in items where !item.done || now.timeIntervalSince(item.date) < doneWindow {
            guard var obj = try JSONSerialization.jsonObject(with: Store.enc.encode(item)) as? [String: Any] else { continue }
            if let vm = item.voicemail, now.timeIntervalSince(item.date) < audioWindow,
               let src = states[item.id]?.audioPath, fm.isReadableFile(atPath: src) {
                let name = "\(vm.id).\((src as NSString).pathExtension.lowercased())"
                let dst = audio.appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(atPath: src, toPath: dst.path) }
                if fm.fileExists(atPath: dst.path), var v = obj["voicemail"] as? [String: Any] {
                    v["audioFile"] = "audio/\(name)"; obj["voicemail"] = v; wantedAudio.insert(name)
                }
            }
            out.append(obj)
        }
        // Remove audio no longer referenced.
        for f in (try? fm.contentsOfDirectory(atPath: audio.path)) ?? [] where !wantedAudio.contains(f) && !f.hasPrefix(".") {
            try? fm.removeItem(at: audio.appendingPathComponent(f))
        }
        let body: [String: Any] = ["version": 1, "items": out, "mac": mac]
        let content = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let unchanged = store.get("cloud.hash") == hash && fm.fileExists(atPath: root.appendingPathComponent("inbox.json").path)
        if unchanged, lastInbox != nil { return }
        var full = body; full["generatedAt"] = ISO8601DateFormatter().string(from: now)
        let data = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
        lastInbox = data
        if unchanged { return }
        // Update inbox.json IN PLACE through a file coordinator (same file identity). Replacing
        // the file with a new one made iOS keep serving its old local copy.
        let dst = root.appendingPathComponent("inbox.json")
        var coordError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: [], error: &coordError) { url in
            do {
                if fm.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    try h.truncate(atOffset: 0); try h.write(contentsOf: data); try h.synchronize()
                } else {
                    try data.write(to: url)
                }
            } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
        try? fm.removeItem(at: root.appendingPathComponent(".inbox.json.tmp"))
        store.set("cloud.hash", hash)
        log("cloud: published \(out.count) items (\(wantedAudio.count) with audio)")
    }
}
