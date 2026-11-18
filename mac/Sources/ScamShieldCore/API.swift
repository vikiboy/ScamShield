import Foundation

/// Routes for docs/API.md plus static web app files.
public final class API {
    let engine: Engine
    let brain: Brain
    let push: WebPush?
    let webRoot: URL
    let version = "1.0"

    public init(engine: Engine, brain: Brain, push: WebPush?, webRoot: URL) {
        self.engine = engine; self.brain = brain; self.push = push; self.webRoot = webRoot
    }

    var store: Store { engine.store }

    /// Requests arriving through `tailscale serve` carry X-Forwarded-For. Tailscale adds
    /// Tailscale-User-Login only for person-owned devices (never for tagged servers), so we
    /// require it and, when configured, match it against the owner's login. Direct loopback
    /// requests (no forwarding headers) come from this Mac and are allowed.
    public static func authorized(_ req: HTTPRequest, allowedLogins: [String]) -> Bool {
        guard req.headers["x-forwarded-for"] != nil || req.headers["tailscale-headers-info"] != nil else { return true }
        guard let login = req.headers["tailscale-user-login"], !login.isEmpty else { return false }
        return allowedLogins.isEmpty || allowedLogins.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard Self.authorized(req, allowedLogins: engine.config.allowedLogins) else { return .error(403, "not allowed") }
        let p = req.path
        let seg = p.split(separator: "/").map(String.init)
        do {
            switch (req.method, seg.first == "api" ? Array(seg.dropFirst()) : []) {
            case ("GET", ["items"]):
                let bucket = req.query["bucket"].flatMap(Bucket.init)
                let items = store.items(bucket: bucket, includeDone: req.query["include_done"] == "1", limit: Int(req.query["limit"] ?? "") ?? 300)
                return .encodable(ItemsResponse(items: items, counts: store.counts(), updatedAt: store.getDate("status.lastIngest")))
            case ("GET", let s) where s.count == 2 && s[0] == "items":
                guard let item = store.item(s[1])?.0 else { return .error(404, "no such item") }
                return .encodable(item)
            case ("POST", let s) where s.count == 3 && s[0] == "items" && s[2] == "label":
                let b = try body(req)
                guard let bucket = (b["bucket"] as? String).flatMap(Bucket.init) else { return .error(400, "bucket required") }
                guard let item = engine.label(id: s[1], bucket: bucket, category: b["category"] as? String, applyToNumber: (b["applyToNumber"] as? Bool) ?? false)
                else { return .error(404, "no such item") }
                return .encodable(item)
            case ("POST", let s) where s.count == 3 && s[0] == "items" && s[2] == "done":
                let b = try body(req)
                guard let item = engine.setDone(id: s[1], done: (b["done"] as? Bool) ?? true) else { return .error(404, "no such item") }
                return .encodable(item)
            case ("POST", ["bulk", "done"]):
                guard let bucket = (try body(req)["bucket"] as? String).flatMap(Bucket.init) else { return .error(400, "bucket required") }
                return .json(["updated": engine.bulkDone(bucket: bucket)])
            case ("GET", let s) where s.count == 2 && s[0] == "audio":
                guard let path = engine.audioPath(voicemailID: s[1]) else { return .error(404, "no audio") }
                let ext = (path as NSString).pathExtension.lowercased()
                let type = ext == "amr" ? "audio/amr" : ext == "m4a" ? "audio/mp4" : "video/quicktime"
                return HTTPResponse(status: 200, headers: ["Content-Type": type, "Cache-Control": "private, max-age=86400"], body: Data(), filePath: path)
            case ("GET", ["blocklist"]):
                let nums = store.blocklist().map { ["number": $0.number, "displayNumber": PhoneNumber.display($0.number), "reason": $0.reason,
                                                    "addedAt": ISO8601DateFormatter().string(from: $0.added)] }
                return .json(["numbers": nums])
            case ("POST", ["blocklist"]):
                let b = try body(req)
                guard let n = b["number"] as? String, !PhoneNumber.key(n).isEmpty else { return .error(400, "number required") }
                engine.setBlocked(number: PhoneNumber.normalize(n), blocked: (b["block"] as? Bool) ?? true)
                return .json(["ok": true])
            case ("GET", ["status"]):
                return .json(status())
            case ("GET", ["push", "key"]):
                guard let push else { return .error(503, "push unavailable") }
                return .json(["publicKey": push.publicKeyBase64URL])
            case ("POST", ["push", "subscribe"]):
                guard let sub = try? JSONDecoder().decode(WebPush.Subscription.self, from: req.body) else { return .error(400, "bad subscription") }
                store.addPushSubscription(endpoint: sub.endpoint, json: String(decoding: req.body, as: UTF8.self))
                return .json(["ok": true])
            case ("POST", ["reminders", "test"]):
                guard req.headers["x-forwarded-for"] == nil, let r = engine.reminders else { return .error(403, "loopback only") }
                try r.sendTestAlert(lead: TimeInterval(engine.config.reminderAlertLeadSeconds))
                return .json(["ok": true, "alertInSeconds": engine.config.reminderAlertLeadSeconds])
            case ("POST", ["push", "test"]):
                let n = engine.sendPush(["title": "ScamShield", "body": "Notifications are working. You'll only hear from me when a call needs you.", "id": "", "url": "/#/attention"])
                return .json(["sent": n])
            case (_, let s) where !s.isEmpty || p.hasPrefix("/api"):
                return .error(404, "unknown endpoint")
            default:
                return staticFile(p)
            }
        } catch {
            return .error(400, "\(error)")
        }
    }

    struct ItemsResponse: Encodable { var items: [Item]; var counts: [String: [String: Int]]; var updatedAt: Date? }

    func body(_ req: HTTPRequest) throws -> [String: Any] {
        if req.body.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
    }

    func status() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func d(_ k: String) -> Any { store.getDate(k).map { iso.string(from: $0) } ?? NSNull() }
        let stats = store.complaintStats()
        return [
            "lastIngest": d("status.lastIngest"), "lastCallSeen": d("status.lastCallSeen"), "lastVoicemailSeen": d("status.lastVoicemailSeen"),
            "models": brain.health(),
            "reputation": ["numbers": stats.numbers, "complaints": stats.rows, "updatedAt": d("rep.lastRefresh")],
            "pending": store.itemIDs(where: "json(state) IS NOT NULL AND json_extract(state, '$.needsModel') = 1").count,
            "permissions": ["contacts": engine.context.contactsStatus, "calendar": engine.context.calendarStatus,
                            "reminders": engine.reminders.map { $0.authorized ? "granted" : "denied" } ?? "off"],
            "pushSubscriptions": store.pushSubscriptions().count,
            "error": engine.lastError ?? NSNull(),
            "version": version,
        ]
    }

    static let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                        "json": "application/json", "webmanifest": "application/manifest+json", "png": "image/png", "svg": "image/svg+xml", "ico": "image/x-icon"]

    func staticFile(_ path: String) -> HTTPResponse {
        var rel = path == "/" ? "index.html" : String(path.drop { $0 == "/" })
        if rel.contains("..") { return .error(400, "bad path") }
        var url = webRoot.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue {
            rel = "index.html"; url = webRoot.appendingPathComponent(rel)
        }
        guard let data = try? Data(contentsOf: url) else { return .error(404, "not found") }
        let ext = url.pathExtension.lowercased()
        var headers = ["Content-Type": Self.types[ext] ?? "application/octet-stream"]
        headers["Cache-Control"] = (rel == "sw.js" || rel == "index.html") ? "no-cache" : "public, max-age=300"
        if rel == "sw.js" { headers["Service-Worker-Allowed"] = "/" }
        return HTTPResponse(status: 200, headers: headers, body: data)
    }
}
