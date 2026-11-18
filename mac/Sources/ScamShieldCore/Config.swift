import Foundation

/// User-editable settings at ~/Library/Application Support/ScamShield/config.json.
public struct Config: Codable, Sendable {
    public var port: Int = 8787
    public var deciderURL: String = "http://127.0.0.1:8009/v1/systemone"
    public var writerURL: String = "http://127.0.0.1:8010/v1/chat/completions"
    public var writerModel: String = "mlx-community/Qwen3.5-4B-MLX-4bit"
    /// Optional free api.data.gov key for the FTC Do Not Call API (https://api.data.gov/signup/).
    public var ftcApiKey: String? = nil
    /// Optional Socrata app token for the FCC dataset (raises rate limits).
    public var fccAppToken: String? = nil
    /// Days of history to import on first run.
    public var backfillDays: Int = 120
    /// Only notify for calls newer than this many minutes when they are processed.
    public var notifyMaxAgeMinutes: Int = 1440
    /// VAPID subject (contact for the push service). Doesn't need to be a real mailbox.
    public var vapidSubject: String = "mailto:scamshield@localhost.localdomain"
    public var thresholds: Classifier.Thresholds = .init()
    /// Directory holding the web app (defaults to the app bundle's Resources/web).
    public var webRoot: String? = nil
    /// Use Contacts / Calendar for context.
    public var useContacts: Bool = true
    public var useCalendar: Bool = true
    /// Deliver to the iPhone through Apple Reminders lists (iCloud).
    public var useReminders: Bool = false
    /// Sync with the ScamShield iPhone app through iCloud Drive (docs/SYNC.md).
    public var useCloudDrive: Bool = true
    /// Direct Wi-Fi path to the iPhone app (Bonjour `_scamshield._tcp`, token-protected).
    public var lanPort: Int = 8790
    public var useLAN: Bool = true
    /// Look up unknown no-voicemail callers on RoboKiller's public page (sends the number only).
    public var useRoboKiller: Bool = true
    /// Seconds after creating a reminder that its alert fires (must exceed iCloud sync time).
    public var reminderAlertLeadSeconds: Int = 90
    /// Tailscale logins allowed to use the app through `tailscale serve` (set by the installer).
    /// Empty: any person-owned tailnet device is allowed; tagged servers never are.
    public var allowedLogins: [String] = []

    public init() {}

    public static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScamShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public static func load() -> Config {
        let url = supportDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url) {
            // Decode leniently: start from defaults, overlay keys present in the file.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] {
                let merged = defaults.merging(obj) { _, new in new }
                if let d = try? JSONSerialization.data(withJSONObject: merged), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
            }
        }
        let c = Config()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: url)
        return c
    }
}
