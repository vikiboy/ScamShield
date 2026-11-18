import Foundation

/// Read-only access to Apple's synced call history and voicemail stores.
/// We never open Apple's live files: each read copies db + -wal + -shm into a private
/// snapshot directory and opens the copy, so Apple's processes are never disturbed and
/// un-checkpointed WAL data (where recent calls live) is included.
public final class AppleSources {
    public static let cocoaEpoch: TimeInterval = 978_307_200

    public let callHistoryPath: String
    public let voicemailStoreDir: String
    let snapshotDir: URL

    public init(home: String = NSHomeDirectory(), snapshotDir: URL) {
        callHistoryPath = home + "/Library/Application Support/CallHistoryDB/CallHistory.storedata"
        voicemailStoreDir = home + "/Library/Group Containers/group.com.apple.FaceTime/com.apple.facetimemessagestored/Data Store"
        self.snapshotDir = snapshotDir
    }

    public var voicemailDBPath: String { voicemailStoreDir + "/FaceTimeMessageStore-local.sqlitedb" }

    /// Paths whose modification indicates new data (used by the watcher).
    public var watchedFiles: [String] {
        [callHistoryPath, callHistoryPath + "-wal", voicemailDBPath, voicemailDBPath + "-wal"]
    }

    public enum AccessError: Error, CustomStringConvertible {
        case noAccess(String)
        public var description: String {
            if case .noAccess(let p) = self { return "Cannot read \(p). Grant Full Disk Access to ScamShield in System Settings → Privacy & Security." }
            return "access error"
        }
    }

    func snapshot(_ path: String, name: String) throws -> String {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path) else { throw AccessError.noAccess(path) }
        let dir = snapshotDir.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (path as NSString).lastPathComponent
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try fm.copyItem(atPath: path + suffix, toPath: dir.appendingPathComponent(base + suffix).path)
        }
        return dir.appendingPathComponent(base).path
    }

    // MARK: Calls

    public func readCalls(since: Date) throws -> [AppleCall] {
        let db = try SQLiteDB(path: try snapshot(callHistoryPath, name: "callhistory"))
        let cols = try db.columns(of: "ZCALLRECORD")
        func c(_ n: String) -> String { cols.contains(n) ? n : "NULL AS \(n)" }
        let sql = """
        SELECT ZUNIQUE_ID, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZADDRESS, ZSERVICE_PROVIDER, ZNAME,
               \(c("ZCOMMUNICATIONTRUSTSCORE")), \(c("ZJUNKCONFIDENCE")), \(c("ZVERIFICATIONSTATUS")), \(c("ZAUTOANSWEREDREASON"))
        FROM ZCALLRECORD WHERE ZDATE >= ? ORDER BY ZDATE ASC
        """
        return try db.query(sql, [since.timeIntervalSince1970 - Self.cocoaEpoch]).compactMap { r in
            guard let uid = r["ZUNIQUE_ID"]?.text, let d = r["ZDATE"]?.double else { return nil }
            return AppleCall(
                uniqueID: uid.uppercased(),
                date: Date(timeIntervalSince1970: d + Self.cocoaEpoch),
                duration: r["ZDURATION"]?.double ?? 0,
                originated: (r["ZORIGINATED"]?.int ?? 0) != 0,
                answered: (r["ZANSWERED"]?.int ?? 0) != 0,
                number: PhoneNumber.normalize(r["ZADDRESS"]?.text),
                provider: r["ZSERVICE_PROVIDER"]?.text ?? "",
                trustScore: r["ZCOMMUNICATIONTRUSTSCORE"]?.int.map(Int.init),
                junkConfidence: r["ZJUNKCONFIDENCE"]?.int.map(Int.init),
                verification: r["ZVERIFICATIONSTATUS"]?.int.map(Int.init),
                autoAnsweredReason: r["ZAUTOANSWEREDREASON"]?.int.map(Int.init),
                name: r["ZNAME"]?.text.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    // MARK: Voicemail

    public func readVoicemails(since: Date) throws -> [AppleVoicemail] {
        // No voicemail store at all (e.g. Phone app never used on this Mac) is not an error.
        if !FileManager.default.fileExists(atPath: voicemailDBPath) && FileManager.default.isReadableFile(atPath: voicemailStoreDir) { return [] }
        let db = try SQLiteDB(path: try snapshot(voicemailDBPath, name: "voicemail"))
        let sql = """
        SELECT hex(ZRECORDUUID) AS rid, hex(ZCALLUUID) AS cid, ZDATECREATED, ZDURATION, ZFROM, ZTRANSCRIPT, ZISREAD, ZFILETYPE
        FROM ZSTOREDMESSAGE
        WHERE ZPROVIDER = 'com.apple.coretelephony' AND ZDATEDELETED IS NULL AND ZDATECREATED >= ?
        ORDER BY ZDATECREATED ASC
        """
        return try db.query(sql, [since.timeIntervalSince1970 - Self.cocoaEpoch]).compactMap { r in
            guard let rid = r["rid"]?.text, !rid.isEmpty, let d = r["ZDATECREATED"]?.double else { return nil }
            let id = Self.dashedUUID(rid)
            var transcript: String?, conf: Double?
            if let blob = r["ZTRANSCRIPT"]?.blob, !blob.isEmpty, let caps = Self.decodeCaptions(blob), !caps.isEmpty {
                transcript = caps.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let cs = caps.compactMap(\.confidence)
                conf = cs.isEmpty ? nil : cs.reduce(0, +) / Double(cs.count) / 100
            }
            let ext = (r["ZFILETYPE"]?.text ?? "MOV")
            let audio = voicemailStoreDir + "/Assets/\(id.prefix(2))/\(id).\(ext)"
            return AppleVoicemail(
                id: id,
                callUUID: r["cid"]?.text.flatMap { $0.count == 32 ? Self.dashedUUID($0) : nil },
                date: Date(timeIntervalSince1970: d + Self.cocoaEpoch),
                duration: r["ZDURATION"]?.double ?? 0,
                number: PhoneNumber.normalize(r["ZFROM"]?.text),
                transcript: (transcript?.isEmpty ?? true) ? nil : transcript,
                transcriptConfidence: conf,
                audioPath: FileManager.default.fileExists(atPath: audio) ? audio : nil,
                isRead: (r["ZISREAD"]?.int ?? 0) != 0)
        }
    }

    public static func dashedUUID(_ hex: String) -> String {
        let h = Array(hex.uppercased())
        guard h.count == 32 else { return hex.uppercased() }
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(h[$0]) }.joined(separator: "-")
    }

    /// Decodes the NSKeyedArchiver array of private `TUCaption` objects without linking
    /// private frameworks: we walk the archive's object table and collect text/confidence.
    public static func decodeCaptions(_ data: Data) -> [(text: String, confidence: Double?)]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any], let rootRef = top["root"] else { return nil }
        func resolve(_ ref: Any?) -> Any? {
            guard let ref, let idx = uidIndex(ref), idx < objects.count else { return ref }
            return objects[idx]
        }
        guard let root = resolve(rootRef) as? [String: Any] else { return nil }
        let refs = (root["NS.objects"] as? [Any]) ?? []
        var out: [(String, Double?)] = []
        for ref in refs {
            guard let obj = resolve(ref) as? [String: Any], let text = resolve(obj["text"]) as? String else { continue }
            out.append((text, obj["confidence"] as? Double))
        }
        return out
    }

    /// CFKeyedArchiverUID has no public Swift API; its description is "<CFKeyedArchiverUID ...>{value = N}".
    static func uidIndex(_ ref: Any) -> Int? {
        let desc = String(describing: ref)
        guard desc.contains("CFKeyedArchiverUID"), let r = desc.range(of: "value = ") else { return nil }
        return Int(desc[r.upperBound...].prefix { $0.isNumber })
    }
}
