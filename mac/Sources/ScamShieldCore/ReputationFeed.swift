import Foundation

/// Downloads public unwanted-call complaints into the local store. Only bulk, date-range
/// queries are made — your own call numbers are never sent anywhere.
///  - FCC Consumer Complaints (Socrata dataset 3xyp-aqkj): no key required.
///  - FTC Do Not Call complaints API: optional, needs a free api.data.gov key (config.ftcApiKey).
public final class ReputationFeed {
    let store: Store
    let config: Config
    let session: URLSession
    let log: (String) -> Void

    public init(store: Store, config: Config, log: @escaping (String) -> Void) {
        self.store = store; self.config = config; self.log = log
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "ScamShield/1.0 (personal call screening)"]
        session = URLSession(configuration: c)
    }

    /// Refresh at most every `interval`. Backfills `backfillDays` on first run.
    public func refreshIfDue(interval: TimeInterval = 12 * 3600, backfillDays: Int = 120) {
        let now = Date()
        if let last = store.getDate("rep.lastRefresh"), now.timeIntervalSince(last) < interval { return }
        let since = store.getDate("rep.fccHighWater").map { $0.addingTimeInterval(-3 * 86400) }
            ?? now.addingTimeInterval(-Double(backfillDays) * 86400)
        do {
            let n = try fetchFCC(since: since)
            log("reputation: FCC +\(n) complaints since \(Self.day(since))")
            store.setDate("rep.fccHighWater", now)
        } catch { log("reputation: FCC fetch failed: \(error)") }
        if let key = config.ftcApiKey, !key.isEmpty {
            let ftcSince = store.getDate("rep.ftcHighWater").map { $0.addingTimeInterval(-2 * 86400) } ?? now.addingTimeInterval(-30 * 86400)
            do {
                let n = try fetchFTC(key: key, since: ftcSince, until: now)
                log("reputation: FTC +\(n) complaints since \(Self.day(ftcSince))")
                store.setDate("rep.ftcHighWater", now)
            } catch { log("reputation: FTC fetch failed: \(error)") }
        }
        store.pruneComplaints(olderThan: now.addingTimeInterval(-365 * 86400))
        store.setDate("rep.lastRefresh", now)
    }

    func getJSON(_ url: URL, headers: [String: String] = [:]) throws -> Any {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        session.dataTask(with: req) { data, resp, err in
            if let err { result = .failure(err) }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.host ?? "")"]))
            } else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try JSONSerialization.jsonObject(with: try result.get())
    }

    func fetchFCC(since: Date) throws -> Int {
        var inserted = 0, offset = 0
        let page = 20000
        while true {
            var c = URLComponents(string: "https://opendata.fcc.gov/resource/3xyp-aqkj.json")!
            c.queryItems = [
                .init(name: "$select", value: ":id,caller_id_number,advertiser_business_phone_number,date_created,state,type_of_call_or_messge"),
                .init(name: "$where", value: "issue='Unwanted Calls' AND type_of_call_or_messge != 'Text Message' AND caller_id_number != '' AND date_created >= '\(Self.day(since))'"),
                .init(name: "$order", value: ":id"),
                .init(name: "$limit", value: String(page)),
                .init(name: "$offset", value: String(offset)),
            ]
            var headers: [String: String] = [:]
            if let t = config.fccAppToken, !t.isEmpty { headers["X-App-Token"] = t }
            guard let rows = try getJSON(c.url!, headers: headers) as? [[String: Any]] else { break }
            let parsed = rows.compactMap { r -> (String, String, String, Date, String?, Bool, String?)? in
                guard let id = r[":id"] as? String, let num = r["caller_id_number"] as? String,
                      let ds = r["date_created"] as? String, let d = Self.parseDate(ds) else { return nil }
                return ("fcc", id, num, d, r["state"] as? String, (r["type_of_call_or_messge"] as? String) == "Prerecorded Voice", nil)
            }
            inserted += try store.addComplaints(parsed.map { (source: $0.0, sid: $0.1, number: $0.2, date: $0.3, state: $0.4, robo: $0.5, subject: $0.6) })
            if rows.count < page { break }
            offset += page
        }
        return inserted
    }

    /// FTC API: max 50 rows per page; we walk the date range in 1-hour windows.
    func fetchFTC(key: String, since: Date, until: Date) throws -> Int {
        var inserted = 0
        var windowStart = since
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "America/New_York")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        while windowStart < until {
            let windowEnd = min(until, windowStart.addingTimeInterval(3600))
            var offset = 0
            while true {
                var c = URLComponents(string: "https://api.ftc.gov/v0/dnc-complaints")!
                c.queryItems = [
                    .init(name: "items_per_page", value: "50"), .init(name: "offset", value: String(offset)),
                    .init(name: "created_date_from", value: "\"\(fmt.string(from: windowStart))\""),
                    .init(name: "created_date_to", value: "\"\(fmt.string(from: windowEnd))\""),
                ]
                guard let obj = try getJSON(c.url!, headers: ["X-Api-Key": key]) as? [String: Any],
                      let data = obj["data"] as? [[String: Any]] else { break }
                let parsed = data.compactMap { rec -> (source: String, sid: String, number: String, date: Date, state: String?, robo: Bool, subject: String?)? in
                    guard let a = rec["attributes"] as? [String: Any], let num = a["company-phone-number"] as? String,
                          num.filter(\.isNumber).count == 10, let ds = a["created-date"] as? String else { return nil }
                    let sid = (rec["id"] as? String) ?? "\(num)|\(ds)"
                    let d = fmt.date(from: ds) ?? Self.parseDate(ds) ?? windowStart
                    return ("ftc", sid, num, d, a["consumer-state"] as? String, (a["recorded-message-or-robocall"] as? String) == "Y", a["subject"] as? String)
                }
                inserted += try store.addComplaints(parsed)
                if data.count < 50 { break }
                offset += 50
            }
            windowStart = windowEnd
            store.setDate("rep.ftcHighWater", windowEnd)   // checkpoint: resume here after rate limits/restarts
        }
        return inserted
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
