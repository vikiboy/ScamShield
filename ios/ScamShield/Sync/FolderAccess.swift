import Foundation
import os

/// Remembers the picked ScamShield folder as a security-scoped bookmark in UserDefaults.
enum FolderAccess {
    enum Source: Equatable, Sendable {
        case bookmark
        /// DEBUG only: `-ScamShieldFolder <absolute path>` launch argument, no bookmark.
        case debugOverride
    }

    enum Resolution: Sendable {
        case resolved(URL, Source)
        case notChosen
        case failed(String)
    }

    private static let bookmarkKey = "folderBookmark"
    private static let log = Logger(subsystem: "local.scamshield", category: "folder")

    static func resolve(defaults: UserDefaults = .standard) -> Resolution {
        #if DEBUG
        if let path = defaults.string(forKey: "ScamShieldFolder"), path.hasPrefix("/") {
            return .resolved(URL(filePath: path, directoryHint: .isDirectory), .debugOverride)
        }
        #endif
        guard let data = defaults.data(forKey: bookmarkKey) else { return .notChosen }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                log.info("Bookmark is stale; saving a fresh one")
                do {
                    try save(url, defaults: defaults)
                } catch {
                    // The old bookmark still resolved; keep using it and try again next launch.
                    log.error("Couldn't refresh stale bookmark: \(error.localizedDescription, privacy: .public)")
                }
            }
            return .resolved(url, .bookmark)
        } catch {
            log.error("Bookmark resolution failed: \(error.localizedDescription, privacy: .public)")
            return .failed("ScamShield lost access to the folder you picked. Choose it again to keep syncing.")
        }
    }

    /// Stores a bookmark for a folder URL returned by the document picker.
    static func save(_ url: URL, defaults: UserDefaults = .standard) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }
}
