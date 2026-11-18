import Foundation
import os

/// Problems reading or writing the iCloud Drive sync folder, phrased for the user.
enum SyncError: LocalizedError, Equatable, Sendable {
    case folderUnavailable
    case inboxMissing
    case inboxDownloading
    case inboxMalformed(String)
    case timedOut
    case io(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            "ScamShield can’t open the folder you picked. It may have been moved, renamed or deleted."
        case .inboxMissing:
            "The folder has no calls yet. Make sure ScamShield is running on your Mac and syncing to this folder."
        case .inboxDownloading:
            "Your calls are still downloading from iCloud Drive."
        case .inboxMalformed(let detail):
            "The calls file from your Mac couldn’t be read (\(detail)). It will be replaced on the Mac’s next update."
        case .timedOut:
            "iCloud Drive didn’t respond in time. Check your connection and try again."
        case .io(let detail):
            detail
        }
    }

    /// Short status line for list headers.
    var shortDescription: String {
        switch self {
        case .folderUnavailable: "Can’t open the ScamShield folder"
        case .inboxMissing: "Waiting for your Mac"
        case .inboxDownloading: "Downloading from iCloud…"
        case .inboxMalformed: "Calls file couldn’t be read"
        case .timedOut: "iCloud Drive isn’t responding"
        case .io: "Couldn’t read from iCloud Drive"
        }
    }
}

/// The picked ScamShield folder in iCloud Drive. Every access is wrapped in a security scope and
/// goes through NSFileCoordinator, which also makes iOS fetch the latest iCloud version. All
/// methods block (coordination can wait on a download), so call them off the main actor.
struct SyncFolder: Sendable {
    static let inboxName = "inbox.json"
    static let correctionsName = "corrections"
    static let coordinationTimeout: TimeInterval = 30

    let url: URL

    private static let log = Logger(subsystem: "local.scamshield", category: "sync")

    // MARK: inbox.json

    func readInbox() throws -> Data {
        try withAccess {
            let inbox = url.appending(path: Self.inboxName, directoryHint: .notDirectory)
            let manager = FileManager.default
            if !manager.fileExists(atPath: inbox.path) {
                guard manager.fileExists(atPath: url.path) else { throw SyncError.folderUnavailable }
                // An iCloud placeholder means the file exists but hasn't been downloaded yet.
                let placeholder = url.appending(path: ".\(Self.inboxName).icloud", directoryHint: .notDirectory)
                guard manager.fileExists(atPath: placeholder.path) else { throw SyncError.inboxMissing }
            }
            // Always ask iCloud for the newest version: a local copy can be stale (the Mac rewrites
            // inbox.json), and iOS otherwise happily serves the old one. Wait briefly for it.
            // iOS often keeps serving an old downloaded copy and never fetches the Mac's newer
            // one. Evict our local copy (the app keeps its own cache, and only the Mac writes this
            // file) so the download below always fetches the current version from iCloud.
            if manager.fileExists(atPath: inbox.path) { try? manager.evictUbiquitousItem(at: inbox) }
            try? manager.startDownloadingUbiquitousItem(at: inbox)
            Self.waitUntilCurrent(inbox, timeout: 12)
            var data: Data?
            try coordinate { coordinator, error in
                coordinator.coordinate(readingItemAt: inbox, options: [], error: error) { readURL in
                    data = try? Data(contentsOf: readURL)
                }
            }
            guard let data else {
                throw manager.fileExists(atPath: inbox.path) ? SyncError.io("inbox.json couldn’t be opened.")
                                                             : SyncError.inboxDownloading
            }
            return data
        }
    }

    /// Polls the iCloud download status until the local copy is the latest (or the timeout passes).
    static func waitUntilCurrent(_ file: URL, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var probe = file
        while Date() < deadline {
            probe.removeAllCachedResourceValues()
            let status = try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == nil || status == .current { return }   // nil: not an iCloud item (e.g. tests)
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            Thread.sleep(forTimeInterval: 0.4)
        }
        log.info("inbox.json still downloading after \(timeout, privacy: .public)s; using the local copy")
    }

    /// True when the folder looks like the ScamShield folder (used to warn during setup).
    func looksLikeScamShieldFolder() -> Bool {
        (try? withAccess {
            let manager = FileManager.default
            let names = ["inbox.json", ".inbox.json.icloud", "README.txt", ".README.txt.icloud", Self.correctionsName]
            return names.contains { manager.fileExists(atPath: url.appending(path: $0).path) }
        }) ?? false
    }

    // MARK: corrections

    /// Writes corrections/<id>.json atomically: a hidden .tmp-<id> file first, then a move,
    /// so the Mac never sees a half-written correction.
    func write(_ correction: Correction) throws {
        let data = try correction.encoded()
        try withAccess {
            let directory = url.appending(path: Self.correctionsName, directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try coordinate { coordinator, error in
                    coordinator.coordinate(writingItemAt: directory, options: [], error: error) { dirURL in
                        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    }
                }
            }
            let temp = directory.appending(path: ".tmp-\(correction.id)", directoryHint: .notDirectory)
            let final = directory.appending(path: "\(correction.id).json", directoryHint: .notDirectory)
            var failure: (any Error)?
            try coordinate { coordinator, error in
                coordinator.coordinate(writingItemAt: temp, options: [], writingItemAt: final, options: .forReplacing,
                                       error: error) { tempURL, finalURL in
                    do {
                        try data.write(to: tempURL)
                        try FileManager.default.moveItem(at: tempURL, to: finalURL)
                        coordinator.item(at: tempURL, didMoveTo: finalURL)
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        failure = error
                    }
                }
            }
            if let failure { throw SyncError.io("Couldn’t save your change to iCloud Drive: \(failure.localizedDescription)") }
        }
    }

    // MARK: voicemail audio

    /// Copies a voicemail recording out of the folder into the app's caches so AVPlayer can play
    /// it without holding the security scope. `relativePath` comes from `voicemail.audioFile`.
    func copyAudio(relativePath: String, to cacheDirectory: URL) throws -> URL {
        guard let source = resolve(relativePath) else { throw SyncError.io("The recording path is invalid.") }
        let destination = cacheDirectory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return try withAccess {
            try? FileManager.default.startDownloadingUbiquitousItem(at: source)
            var failure: (any Error)?
            do {
                try coordinate { coordinator, error in
                    coordinator.coordinate(readingItemAt: source, options: [], error: error) { readURL in
                        let partial = cacheDirectory.appending(path: ".partial-\(UUID().uuidString)")
                        do {
                            try FileManager.default.copyItem(at: readURL, to: partial)
                            try FileManager.default.moveItem(at: partial, to: destination)
                        } catch {
                            try? FileManager.default.removeItem(at: partial)
                            failure = error
                        }
                    }
                }
            } catch SyncError.timedOut {
                throw SyncError.timedOut
            } catch {
                failure = error
            }
            if let failure {
                Self.log.error("Audio copy failed: \(failure.localizedDescription, privacy: .public)")
                throw SyncError.io("The recording isn’t available on this iPhone yet.")
            }
            return destination
        }
    }

    /// Resolves a folder-relative path, refusing anything that escapes the folder.
    func resolve(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/")
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let resolved = url.appending(path: relativePath, directoryHint: .notDirectory).standardizedFileURL
        let root = url.standardizedFileURL.path
        return resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? resolved : nil
    }

    // MARK: plumbing

    /// Security scope around folder access. `startAccessing…` returns false for URLs that aren't
    /// security scoped (the DEBUG `-ScamShieldFolder` override); that is not an error.
    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Runs one coordinated operation, cancelling it if iCloud doesn't respond in time.
    private func coordinate(_ body: (NSFileCoordinator, NSErrorPointer) -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let box = CoordinatorBox(coordinator)
        let timeout = DispatchWorkItem { box.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.coordinationTimeout, execute: timeout)
        defer { timeout.cancel() }
        var error: NSError?
        body(coordinator, &error)
        if let error {
            if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError { throw SyncError.timedOut }
            if error.domain == NSCocoaErrorDomain,
               [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                throw SyncError.inboxMissing
            }
            Self.log.error("Coordination failed: \(error.localizedDescription, privacy: .public)")
            throw SyncError.io(error.localizedDescription)
        }
    }
}

/// NSFileCoordinator.cancel() is documented as callable from any thread; this lets the timeout
/// closure hold the coordinator.
private final class CoordinatorBox: @unchecked Sendable {
    private let coordinator: NSFileCoordinator
    init(_ coordinator: NSFileCoordinator) { self.coordinator = coordinator }
    func cancel() { coordinator.cancel() }
}

/// Runs blocking file work away from the main actor.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
