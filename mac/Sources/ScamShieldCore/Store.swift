import Foundation

/// The API-facing record (see docs/API.md).
public struct Item: Codable, Sendable, Equatable {
    public struct Voicemail: Codable, Sendable, Equatable {
        public var id: String
        public var durationSec: Double
        public var transcript: String?
        public var transcriptConfidence: Double?
        public var hasAudio: Bool
    }
    public struct Callback: Codable, Sendable, Equatable { public var recommended: Bool; public var probability: Double }
    public struct Caller: Codable, Sendable, Equatable { public var name: String?; public var organization: String? }
    public struct Rep: Codable, Sendable, Equatable {
        public var score: Double; public var complaints: Int; public var lastReported: Date?; public var robocallShare: Double
    }

    public var id: String
    public var number: String
    public var displayNumber: String
    public var contactName: String?
    public var date: Date
    public var answered: Bool
    public var durationSec: Double
    public var callCount: Int
    public var voicemail: Voicemail?
    public var bucket: Bucket
    public var category: String
    public var confidence: Double
    public var callback: Callback
    public var caller: Caller
    public var summary: String
    public var reasons: [String]
    public var reputation: Rep
    public var userLabeled: Bool
    public var done: Bool
    public var notified: Bool
}

/// Internal processing record kept alongside each item.
public struct ItemState: Codable, Sendable {
    public var callUID: String?
    public var voicemailID: String?
    public var contentKey: String          // changes when new content (voicemail/transcript) arrives
    public var judgment: ContentJudgment?
    public var needsModel: Bool            // content present but models were unavailable
    public var audioPath: String?
    // Apple's per-call signals, kept so items can be re-decided without re-reading Apple's store.
    public var appleTrust: Int? = nil
    public var appleJunkConfidence: Int? = nil
    public var appleName: String? = nil
}

/// ScamShield's own database (~/Library/Application Support/ScamShield/scamshield.sqlite).
/// All access is serialized through a lock.
public final class Store: @unchecked Sendable {
    let db: SQLiteDB
    let lock = NSRecursiveLock()

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    func sync<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS items(
          id TEXT PRIMARY KEY, number TEXT, date REAL, bucket TEXT, category TEXT, done INT DEFAULT 0,
          notified INT DEFAULT 0, user_labeled INT DEFAULT 0, json TEXT NOT NULL, state TEXT NOT NULL, updated REAL);
        CREATE INDEX IF NOT EXISTS items_bucket ON items(bucket, done, date);
        CREATE INDEX IF NOT EXISTS items_number ON items(number);
        CREATE TABLE IF NOT EXISTS calls(uid TEXT PRIMARY KEY, number TEXT, date REAL, originated INT, connected INT);
        CREATE INDEX IF NOT EXISTS calls_number ON calls(number, date);
        CREATE TABLE IF NOT EXISTS number_rules(number TEXT PRIMARY KEY, bucket TEXT, category TEXT, updated REAL);
        CREATE TABLE IF NOT EXISTS org_rules(org TEXT PRIMARY KEY, bucket TEXT, updated REAL);
        CREATE TABLE IF NOT EXISTS blocklist(number TEXT PRIMARY KEY, reason TEXT, added REAL);
        CREATE TABLE IF NOT EXISTS push_subs(endpoint TEXT PRIMARY KEY, json TEXT, added REAL, failures INT DEFAULT 0);
        CREATE TABLE IF NOT EXISTS labels(item_id TEXT, bucket TEXT, category TEXT, at REAL, model_bucket TEXT, judgment TEXT);
        CREATE TABLE IF NOT EXISTS reputation(numkey TEXT PRIMARY KEY, complaints INT, weighted REAL, last REAL, robo INT, states TEXT);
        CREATE TABLE IF NOT EXISTS complaints(source TEXT, sid TEXT, numkey TEXT, date REAL, state TEXT, robo INT, subject TEXT, PRIMARY KEY(source, sid));
        CREATE INDEX IF NOT EXISTS complaints_num ON complaints(numkey);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
        """)
    }

    // MARK: kv

    public func get(_ key: String) -> String? {
        sync { (try? db.query("SELECT value FROM kv WHERE key=?", [key]))?.first?["value"]?.text }
    }
    public func set(_ key: String, _ value: String?) {
        sync { _ = try? db.run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
    }
    /// Keys under `prefix` (prefix stripped), excluding tombstoned values.
    public func kvKeys(prefix: String) -> [String] {
        sync { ((try? db.query("SELECT key FROM kv WHERE key LIKE ? AND value != 'deleted'", [prefix + "%"])) ?? [])
            .compactMap { $0["key"]?.text.map { String($0.dropFirst(prefix.count)) } } }
    }
    public func kvMap(prefix: String) -> [String: String] {
        sync {
            var out: [String: String] = [:]
            for r in (try? db.query("SELECT key, value FROM kv WHERE key LIKE ?", [prefix + "%"])) ?? [] {
                if let k = r["key"]?.text, let v = r["value"]?.text { out[String(k.dropFirst(prefix.count))] = v }
            }
            return out
        }
    }
    public func getDate(_ key: String) -> Date? { get(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
    public func setDate(_ key: String, _ d: Date) { set(key, String(d.timeIntervalSince1970)) }

    // MARK: items

    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func item(_ id: String) -> (Item, ItemState)? {
        sync {
            guard let r = try? db.query("SELECT json, state FROM items WHERE id=?", [id]).first,
                  let j = r["json"]?.text, let s = r["state"]?.text,
                  let item = try? Self.dec.decode(Item.self, from: Data(j.utf8)),
                  let st = try? Self.dec.decode(ItemState.self, from: Data(s.utf8)) else { return nil }
            return (item, st)
        }
    }

    public func save(_ item: Item, _ state: ItemState) throws {
        let j = String(decoding: try Self.enc.encode(item), as: UTF8.self)
        let s = String(decoding: try Self.enc.encode(state), as: UTF8.self)
        try sync {
            try db.run("""
            INSERT INTO items(id,number,date,bucket,category,done,notified,user_labeled,json,state,updated) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET number=excluded.number,date=excluded.date,bucket=excluded.bucket,category=excluded.category,
              done=excluded.done,notified=excluded.notified,user_labeled=excluded.user_labeled,json=excluded.json,state=excluded.state,updated=excluded.updated
            """, [item.id, item.number, item.date, item.bucket.rawValue, item.category, item.done, item.notified, item.userLabeled, j, s, Date()])
        }
    }

    public func items(bucket: Bucket?, includeDone: Bool, limit: Int) -> [Item] {
        sync {
            var sql = "SELECT json FROM items WHERE 1=1"
            var params: [Any?] = []
            if let bucket { sql += " AND bucket=?"; params.append(bucket.rawValue) }
            if !includeDone { sql += " AND done=0" }
            sql += " ORDER BY date DESC LIMIT ?"; params.append(limit)
            return ((try? db.query(sql, params)) ?? []).compactMap { r in
                r["json"]?.text.flatMap { try? Self.dec.decode(Item.self, from: Data($0.utf8)) }
            }
        }
    }

    public func delete(_ id: String) { sync { _ = try? db.run("DELETE FROM items WHERE id=?", [id]) } }

    /// All items with their processing state (for publishing).
    public func itemsWithState(limit: Int = 3000) -> [(Item, ItemState)] {
        sync {
            ((try? db.query("SELECT json, state FROM items ORDER BY date DESC LIMIT ?", [limit])) ?? []).compactMap { r in
                guard let j = r["json"]?.text, let s = r["state"]?.text,
                      let i = try? Self.dec.decode(Item.self, from: Data(j.utf8)),
                      let st = try? Self.dec.decode(ItemState.self, from: Data(s.utf8)) else { return nil }
                return (i, st)
            }
        }
    }

    public func itemIDs(where clause: String, _ params: [Any?] = []) -> [String] {
        sync { ((try? db.query("SELECT id FROM items WHERE \(clause)", params)) ?? []).compactMap { $0["id"]?.text } }
    }

    public func counts() -> [String: [String: Int]] {
        sync {
            var out: [String: [String: Int]] = [:]
            for b in Bucket.allCases { out[b.rawValue] = ["open": 0, "total": 0] }
            for r in (try? db.query("SELECT bucket, SUM(done=0) AS open, COUNT(*) AS total FROM items GROUP BY bucket")) ?? [] {
                guard let b = r["bucket"]?.text else { continue }
                out[b] = ["open": Int(r["open"]?.int ?? 0), "total": Int(r["total"]?.int ?? 0)]
            }
            return out
        }
    }

    // MARK: call history mirror (for context: outgoing calls, repeats)

    public func recordCalls(_ calls: [AppleCall]) throws {
        try sync {
            try db.transaction {
                for c in calls {
                    try db.run("INSERT OR REPLACE INTO calls(uid,number,date,originated,connected) VALUES(?,?,?,?,?)",
                               [c.uniqueID, PhoneNumber.key(c.number), c.date, c.originated, c.connected])
                }
            }
        }
    }

    public struct History { public var outgoing: Int; public var answeredIncoming: Int; public var last24h: Int; public var last15m: Int }

    public func history(number: String, at date: Date, excluding uid: String?) -> History {
        let key = PhoneNumber.key(number)
        guard !key.isEmpty else { return History(outgoing: 0, answeredIncoming: 0, last24h: 1, last15m: 1) }
        return sync {
            let t = date.timeIntervalSince1970
            let r = (try? db.query("""
              SELECT SUM(originated=1 AND date < ?) AS o, SUM(originated=0 AND connected=1 AND date < ? AND uid != ?) AS a,
                     SUM(originated=0 AND date BETWEEN ? AND ?) AS d, SUM(originated=0 AND date BETWEEN ? AND ?) AS m
              FROM calls WHERE number=?
              """, [t, t, uid ?? "", t - 86400, t + 60, t - 900, t + 60, key]))?.first
            return History(outgoing: Int(r?["o"]?.int ?? 0), answeredIncoming: Int(r?["a"]?.int ?? 0),
                           last24h: max(1, Int(r?["d"]?.int ?? 1)), last15m: max(1, Int(r?["m"]?.int ?? 1)))
        }
    }

    // MARK: rules & blocklist

    public func numberRule(_ number: String) -> (Bucket, String?)? {
        sync {
            guard let r = (try? db.query("SELECT bucket, category FROM number_rules WHERE number=?", [PhoneNumber.key(number)]))?.first,
                  let b = r["bucket"]?.text.flatMap(Bucket.init) else { return nil }
            return (b, r["category"]?.text)
        }
    }
    public func setNumberRule(_ number: String, bucket: Bucket, category: String?) {
        sync { _ = try? db.run("INSERT OR REPLACE INTO number_rules(number,bucket,category,updated) VALUES(?,?,?,?)", [PhoneNumber.key(number), bucket.rawValue, category, Date()]) }
    }
    public static func orgKey(_ org: String) -> String {
        org.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }
    public func orgRule(_ org: String?) -> Bucket? {
        guard let org, !Self.orgKey(org).isEmpty else { return nil }
        return sync { (try? db.query("SELECT bucket FROM org_rules WHERE org=?", [Self.orgKey(org)]))?.first?["bucket"]?.text.flatMap(Bucket.init) }
    }
    public func setOrgRule(_ org: String, bucket: Bucket) {
        let k = Self.orgKey(org); guard !k.isEmpty else { return }
        sync { _ = try? db.run("INSERT OR REPLACE INTO org_rules(org,bucket,updated) VALUES(?,?,?)", [k, bucket.rawValue, Date()]) }
    }
    public func recordLabel(itemID: String, bucket: Bucket, category: String?, modelBucket: Bucket, judgment: ContentJudgment?) {
        let j = judgment.flatMap { try? Self.enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        sync { _ = try? db.run("INSERT INTO labels(item_id,bucket,category,at,model_bucket,judgment) VALUES(?,?,?,?,?,?)", [itemID, bucket.rawValue, category, Date(), modelBucket.rawValue, j]) }
    }

    /// Transcripts of messages the user labelled (latest label per item; Review labels excluded).
    public func labelledTranscripts() -> [(bucket: Bucket, category: String?, text: String)] {
        sync {
            let sql = """
            SELECT l.bucket, l.category, json_extract(i.json, '$.voicemail.transcript') AS t
            FROM labels l JOIN items i ON i.id = l.item_id
            WHERE l.rowid IN (SELECT MAX(rowid) FROM labels GROUP BY item_id) AND l.bucket != 'review' AND t IS NOT NULL
            """
            return ((try? db.query(sql)) ?? []).compactMap { r in
                guard let b = r["bucket"]?.text.flatMap(Bucket.init), let t = r["t"]?.text else { return nil }
                return (b, r["category"]?.text, t)
            }
        }
    }

    public func isBlocked(_ number: String) -> Bool {
        sync { !((try? db.query("SELECT 1 FROM blocklist WHERE number=?", [PhoneNumber.key(number)])) ?? []).isEmpty }
    }
    public func setBlocked(_ number: String, _ blocked: Bool, reason: String = "Blocked by you") {
        sync {
            if blocked { _ = try? db.run("INSERT OR REPLACE INTO blocklist(number,reason,added) VALUES(?,?,?)", [PhoneNumber.key(number), reason, Date()]) }
            else { _ = try? db.run("DELETE FROM blocklist WHERE number=?", [PhoneNumber.key(number)]) }
        }
    }
    public func blocklist() -> [(number: String, reason: String, added: Date)] {
        sync {
            ((try? db.query("SELECT number, reason, added FROM blocklist ORDER BY added DESC")) ?? []).compactMap { r in
                guard let n = r["number"]?.text else { return nil }
                return (PhoneNumber.normalize(n), r["reason"]?.text ?? "", Date(timeIntervalSince1970: r["added"]?.double ?? 0))
            }
        }
    }

    // MARK: push subscriptions

    public func addPushSubscription(endpoint: String, json: String) {
        sync { _ = try? db.run("INSERT OR REPLACE INTO push_subs(endpoint,json,added,failures) VALUES(?,?,?,0)", [endpoint, json, Date()]) }
    }
    public func pushSubscriptions() -> [String] {
        sync { ((try? db.query("SELECT json FROM push_subs")) ?? []).compactMap { $0["json"]?.text } }
    }
    public func removePushSubscription(endpoint: String) {
        sync { _ = try? db.run("DELETE FROM push_subs WHERE endpoint=?", [endpoint]) }
    }

    // MARK: reputation

    public func addComplaints(_ rows: [(source: String, sid: String, number: String, date: Date, state: String?, robo: Bool, subject: String?)]) throws -> Int {
        try sync {
            try db.transaction {
                var n = 0
                for r in rows {
                    let key = PhoneNumber.key(r.number)
                    guard key.count == 10 else { continue }
                    n += try db.run("INSERT OR IGNORE INTO complaints(source,sid,numkey,date,state,robo,subject) VALUES(?,?,?,?,?,?,?)",
                                    [r.source, r.sid, key, r.date, r.state, r.robo, r.subject])
                }
                return n
            }
        }
    }

    /// Recency-weighted complaint score: Σ exp(-age/τ), τ = 30 days, deduped per (number, day, state).
    public func reputation(_ number: String, now: Date = Date()) -> Reputation {
        let key = PhoneNumber.key(number)
        guard key.count == 10 else { return .clean }
        return sync {
            let rows = (try? db.query("SELECT date, state, robo FROM complaints WHERE numkey=?", [key])) ?? []
            guard !rows.isEmpty else { return .clean }
            var seen = Set<String>(), weighted = 0.0, robo = 0, last = 0.0, states = Set<String>()
            for r in rows {
                let d = r["date"]?.double ?? 0, st = r["state"]?.text ?? ""
                let dedupe = "\(Int(d / 86400))|\(st)"
                guard seen.insert(dedupe).inserted else { continue }
                weighted += exp(-(now.timeIntervalSince1970 - d) / (30 * 86400))
                if (r["robo"]?.int ?? 0) != 0 { robo += 1 }
                if !st.isEmpty { states.insert(st) }
                last = max(last, d)
            }
            let n = seen.count
            // Saturating score; single reports count little (typos, neighbour spoofing).
            var score = 1 - exp(-weighted / 3)
            if n < 2 { score *= 0.3 }
            if states.count >= 3 { score = min(1, score * 1.2) }
            return Reputation(score: score, complaints: n, lastReported: last > 0 ? Date(timeIntervalSince1970: last) : nil,
                              robocallShare: Double(robo) / Double(n), states: states.count)
        }
    }

    public func complaintStats() -> (numbers: Int, rows: Int) {
        sync {
            let r = (try? db.query("SELECT COUNT(DISTINCT numkey) AS n, COUNT(*) AS c FROM complaints"))?.first
            return (Int(r?["n"]?.int ?? 0), Int(r?["c"]?.int ?? 0))
        }
    }

    public func pruneComplaints(olderThan: Date) {
        sync { _ = try? db.run("DELETE FROM complaints WHERE date < ?", [olderThan]) }
    }
}
