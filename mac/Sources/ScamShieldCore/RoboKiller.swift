import Foundation

/// What a public lookup site says about a number.
public struct OnlineReport: Codable, Sendable, Equatable {
    public var source: String            // "RoboKiller"
    public var blocked: Bool             // RoboKiller's own verdict ("Blocked" vs "Allowed")
    public var category: String?         // e.g. "Loan Offer", "Scam", "Telemarketing", "Appointment Reminder"
    public var negativeReputation: Bool
    public var userReports: Int
    public var totalCalls: Int
    public var transcript: String?

    public init(source: String = "RoboKiller", blocked: Bool = false, category: String? = nil, negativeReputation: Bool = false, userReports: Int = 0, totalCalls: Int = 0, transcript: String? = nil) {
        self.source = source; self.blocked = blocked; self.category = category; self.negativeReputation = negativeReputation
        self.userReports = userReports; self.totalCalls = totalCalls; self.transcript = transcript
    }

    static let spamWords = ["loan", "scam", "fraud", "spam", "robocall", "telemarket", "debt", "warranty", "insurance", "political", "survey", "solicit", "sales", "impersonat"]

    /// The ScamShield scam category this report implies, or nil when it isn't evidence of spam.
    public var scamCategory: String? {
        let c = (category ?? "").lowercased()
        // Legitimate-sounding categories are never treated as spam evidence on their own.
        let legit = ["appointment", "pharmacy", "delivery", "bank", "school", "medical", "doctor", "hospital", "government", "utility", "airline", "reminder"]
        if legit.contains(where: { c.contains($0) }) { return (negativeReputation && userReports >= 3) ? "spam_other" : nil }
        if c.contains("loan") || c.contains("debt") { return "loan_offer" }
        if c.contains("fraud") || c.contains("impersonat") || c.contains("scam") { return "fraud" }
        if c.contains("telemarket") || c.contains("sales") || c.contains("warranty") || c.contains("insurance") { return "telemarketing" }
        if c.contains("robocall") || c.contains("political") || c.contains("survey") { return "robocall" }
        if Self.spamWords.contains(where: { c.contains($0) }) || blocked { return "spam_other" }
        if negativeReputation && userReports >= 2 { return "spam_other" }
        return nil
    }

    public var summaryLine: String {
        var parts: [String] = []
        if let category, !category.isEmpty { parts.append(category) }
        if blocked { parts.append("blocked by RoboKiller") }
        if userReports > 0 { parts.append("\(userReports) user report\(userReports == 1 ? "" : "s")") }
        if totalCalls > 0 { parts.append("\(totalCalls) calls seen") }
        return "RoboKiller: " + (parts.isEmpty ? "no reports" : parts.joined(separator: ", "))
    }
}

/// Opt-in online lookup (config.useRoboKiller). Sends ONLY the caller's number to RoboKiller's
/// public lookup page, and only for unknown callers who left no voicemail. Results are cached.
public final class RoboKillerLookup {
    let store: Store
    let session: URLSession
    let log: (String) -> Void
    private var lastRequest = Date.distantPast

    public init(store: Store, log: @escaping (String) -> Void) {
        self.store = store; self.log = log
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        session = URLSession(configuration: c)
    }

    /// Cached result, refreshed when older than `maxAge`. Returns nil on failure (no effect on decisions).
    public func report(for number: String, maxAge: TimeInterval = 86400) -> OnlineReport? {
        let key = PhoneNumber.key(number)
        guard key.count == 10, number.hasPrefix("+1") else { return nil }
        if let cached = store.get("rk.\(key)"), let sep = cached.firstIndex(of: "|"),
           let t = Double(cached[..<sep]), Date().timeIntervalSince1970 - t < maxAge {
            return try? JSONDecoder().decode(OnlineReport.self, from: Data(cached[cached.index(after: sep)...].utf8))
        }
        // Be polite: at most one request every 3 seconds.
        let wait = 3 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lastRequest = Date()
        let digits = Array(key)
        let path = "\(String(digits[0..<3]))-\(String(digits[3..<6]))-\(String(digits[6..<10]))"
        guard let url = URL(string: "https://lookup.robokiller.com/p/\(path)") else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var html: String?
        session.dataTask(with: url) { data, resp, err in
            if err == nil, (resp as? HTTPURLResponse)?.statusCode == 200, let data { html = String(decoding: data, as: UTF8.self) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        guard let html, let rep = Self.parse(html) else { log("robokiller: lookup failed for …\(key.suffix(4))"); return nil }
        if let data = try? JSONEncoder().encode(rep) {
            store.set("rk.\(key)", "\(Date().timeIntervalSince1970)|" + String(decoding: data, as: UTF8.self))
        }
        log("robokiller: …\(key.suffix(4)) → \(rep.summaryLine)")
        return rep
    }

    /// Parses lookup.robokiller.com/p/<number>. Returns nil if the page structure is unrecognized.
    public static func parse(_ html: String) -> OnlineReport? {
        func h3(afterID id: String) -> String? {
            guard let r = html.range(of: "id=\"\(id)\"") else { return nil }
            return firstH3(in: html[r.upperBound...])
        }
        func firstH3(in s: Substring) -> String? {
            guard let a = s.range(of: "<h3"), let gt = s[a.upperBound...].firstIndex(of: ">"),
                  let close = s[gt...].range(of: "</h3>") else { return nil }
            return clean(String(s[s.index(after: gt)..<close.lowerBound]))
        }
        guard let status = h3(afterID: "roboStatus") else { return nil }
        var rep = OnlineReport()
        rep.blocked = status.lowercased().contains("block")
        rep.negativeReputation = (h3(afterID: "userReputation") ?? "").lowercased().contains("negative")
        rep.userReports = Int(h3(afterID: "userReports") ?? "") ?? 0
        rep.totalCalls = Int((h3(afterID: "totalCall") ?? "").filter(\.isNumber)) ?? 0
        if let r = html.range(of: "class=\"reported-category\"") { rep.category = firstH3(in: html[r.upperBound...]) }
        if let r = html.range(of: "class=\"call-box\""), let p = html[r.upperBound...].range(of: "<p>"),
           let e = html[p.upperBound...].range(of: "</p>") {
            let t = clean(String(html[p.upperBound..<e.lowerBound]))
            rep.transcript = t.isEmpty ? nil : String(t.prefix(600))
        }
        return rep
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
