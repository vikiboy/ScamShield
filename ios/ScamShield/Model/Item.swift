import Foundation

/// The three lists the Mac sorts missed calls into (docs/API.md).
enum Bucket: String, Codable, CaseIterable, Identifiable, Sendable {
    case attention, review, scam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention: "Attention"
        case .review: "Review"
        case .scam: "Scams"
        }
    }

    var categories: [String] {
        switch self {
        case .attention:
            ["personal", "known_contact", "appointment", "medical", "delivery", "recruiter", "business",
             "financial_legit", "callback_request", "repeated_caller"]
        case .review: ["no_message", "unclear"]
        case .scam: ["fraud", "robocall", "loan_offer", "telemarketing", "spam_other", "blocked"]
        }
    }

    var defaultCategory: String {
        switch self {
        case .attention: "personal"
        case .review: "unclear"
        case .scam: "spam_other"
        }
    }
}

enum Category {
    private static let labels: [String: String] = [
        "personal": "Personal", "known_contact": "Contact", "appointment": "Appointment", "medical": "Medical",
        "delivery": "Delivery", "recruiter": "Recruiter", "business": "Business", "financial_legit": "Bank / Finance",
        "callback_request": "Call-back request", "repeated_caller": "Repeated caller", "no_message": "No message",
        "unclear": "Unclear", "fraud": "Fraud", "robocall": "Robocall", "loan_offer": "Loan offer",
        "telemarketing": "Telemarketing", "spam_other": "Other spam", "blocked": "Blocked",
    ]

    static func label(_ category: String) -> String {
        if let label = labels[category] { return label }
        let spaced = category.replacingOccurrences(of: "_", with: " ")
        return spaced.isEmpty ? "Other" : spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// One missed call, exactly the `Item` JSON from docs/API.md. The Mac omits keys whose value
/// is null, so every field decodes leniently and falls back to an empty/neutral value.
struct Item: Decodable, Hashable, Identifiable, Sendable {
    struct Voicemail: Decodable, Hashable, Sendable {
        var id: String?
        var durationSec: Double?
        var transcript: String?
        var transcriptConfidence: Double?
        var hasAudio: Bool = false
        /// Relative path inside the sync folder, e.g. "audio/<id>.mov" (SYNC.md).
        var audioFile: String?
    }

    struct Callback: Decodable, Hashable, Sendable {
        var recommended: Bool = false
        var probability: Double?
    }

    struct Caller: Decodable, Hashable, Sendable {
        var name: String?
        var organization: String?
    }

    struct Reputation: Decodable, Hashable, Sendable {
        var score: Double?
        var complaints: Int?
        var lastReported: Date?
        var robocallShare: Double?
    }

    var id: String
    var number: String = ""
    var displayNumber: String?
    var contactName: String?
    var date: Date?
    var answered: Bool = false
    var durationSec: Double = 0
    var callCount: Int = 1
    var voicemail: Voicemail?
    var bucket: Bucket
    var category: String
    var confidence: Double?
    var callback: Callback?
    var caller: Caller?
    var summary: String?
    var reasons: [String] = []
    var reputation: Reputation?
    var userLabeled: Bool = false
    var done: Bool = false
    var notified: Bool = false

    init(id: String, bucket: Bucket, category: String) {
        self.id = id
        self.bucket = bucket
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, displayNumber, contactName, date, answered, durationSec, callCount, voicemail, bucket,
             category, confidence, callback, caller, summary, reasons, reputation, userLabeled, done, notified
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bucket = try c.decode(Bucket.self, forKey: .bucket)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? bucket.defaultCategory
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        displayNumber = try c.decodeIfPresent(String.self, forKey: .displayNumber)
        contactName = try c.decodeIfPresent(String.self, forKey: .contactName)
        date = try c.decodeIfPresent(Date.self, forKey: .date)
        answered = try c.decodeIfPresent(Bool.self, forKey: .answered) ?? false
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        callCount = try c.decodeIfPresent(Int.self, forKey: .callCount) ?? 1
        voicemail = try c.decodeIfPresent(Voicemail.self, forKey: .voicemail)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        callback = try c.decodeIfPresent(Callback.self, forKey: .callback)
        caller = try c.decodeIfPresent(Caller.self, forKey: .caller)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        reputation = try c.decodeIfPresent(Reputation.self, forKey: .reputation)
        userLabeled = try c.decodeIfPresent(Bool.self, forKey: .userLabeled) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? false
    }
}

extension Item.Voicemail {
    private enum CodingKeys: String, CodingKey {
        case id, durationSec, transcript, transcriptConfidence, hasAudio, audioFile
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        transcriptConfidence = try c.decodeIfPresent(Double.self, forKey: .transcriptConfidence)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
    }
}

extension Item.Callback {
    private enum CodingKeys: String, CodingKey { case recommended, probability }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        probability = try c.decodeIfPresent(Double.self, forKey: .probability)
    }
}

// MARK: - Presentation helpers (ported from web/app.js)

extension Item {
    /// FaceTime calls can come from an Apple ID email instead of a phone number. Those can be
    /// called back over FaceTime, but not dialled, blocked or looked up in the reputation data.
    var hasPhoneNumber: Bool { !number.isEmpty && !number.contains("@") }

    /// Scam callers often claim to be someone they are not, so only trust Contacts there.
    var title: String {
        if let contactName { return contactName }
        if bucket != .scam, let claimed = caller?.organization ?? caller?.name { return claimed }
        return shownNumber ?? "No Caller ID"
    }

    var shownNumber: String? {
        if let displayNumber, !displayNumber.isEmpty { return displayNumber }
        return number.isEmpty ? nil : number
    }

    /// Secondary line under the title: claimed identity for scams, the person at an
    /// organization, and the number when it isn't already the title.
    var subtitle: String {
        var parts: [String] = []
        let org = caller?.organization
        let person = caller?.name
        if bucket == .scam, contactName == nil, let claimed = org ?? person {
            parts.append("Claims to be \(claimed)")
        } else if let org, let person, title == org {
            parts.append(person)
        }
        if let shown = shownNumber {
            if shown != title { parts.append(shown) }
        } else {
            parts.append("Caller ID withheld")
        }
        return parts.joined(separator: " · ")
    }

    /// Whether this caller has a name we can show initials for (never for scams).
    var avatarName: String? {
        guard bucket != .scam else { return nil }
        return contactName ?? caller?.organization ?? caller?.name
    }

    var showsCallBack: Bool {
        !number.isEmpty && (callback?.recommended == true || bucket == .attention)
    }

    var callbackRecommended: Bool { callback?.recommended == true }

    var callBackURL: URL? {
        guard !number.isEmpty else { return nil }
        if hasPhoneNumber {
            let dialable = number.filter { $0.isNumber || $0 == "+" }
            return URL(string: "tel:\(dialable)")
        }
        let handle = number.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? number
        return URL(string: "facetime-audio:\(handle)")
    }

    var callBackLabel: String { hasPhoneNumber ? "Call Back" : "Call Back with FaceTime" }

    var hasVoicemailDuration: Bool { (voicemail?.durationSec ?? 0) > 0 }
}
