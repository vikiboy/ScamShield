import Foundation

public enum Bucket: String, Codable, CaseIterable, Sendable {
    case attention, review, scam
}

/// Phone number helpers (US-centric, E.164 output where possible).
public enum PhoneNumber {
    public static func normalize(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.contains("@") { return raw.lowercased() }   // FaceTime email handles
        let digits = raw.filter(\.isNumber)
        if raw.hasPrefix("+") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return digits.isEmpty ? raw : digits
    }

    /// Last 10 digits, for loose matching across formats.
    public static func key(_ raw: String?) -> String {
        let d = (raw ?? "").filter(\.isNumber)
        return String(d.suffix(10))
    }

    public static func display(_ e164: String) -> String {
        guard e164.hasPrefix("+1"), e164.count == 12 else { return e164.isEmpty ? "No Caller ID" : e164 }
        let d = Array(e164.dropFirst(2))
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}

/// A call record read from Apple's CallHistory store.
public struct AppleCall: Sendable, Equatable {
    public var uniqueID: String
    public var date: Date
    public var duration: Double
    public var originated: Bool
    public var answered: Bool
    public var number: String       // normalized
    public var provider: String
    public var trustScore: Int?     // ZCOMMUNICATIONTRUSTSCORE (0 blocked … 8 contact, 9 vip)
    public var junkConfidence: Int?
    public var verification: Int?   // STIR/SHAKEN status
    public var autoAnsweredReason: Int?
    public var name: String?

    public init(uniqueID: String, date: Date, duration: Double, originated: Bool, answered: Bool, number: String, provider: String, trustScore: Int? = nil, junkConfidence: Int? = nil, verification: Int? = nil, autoAnsweredReason: Int? = nil, name: String? = nil) {
        self.uniqueID = uniqueID; self.date = date; self.duration = duration; self.originated = originated
        self.answered = answered; self.number = number; self.provider = provider; self.trustScore = trustScore
        self.junkConfidence = junkConfidence; self.verification = verification; self.autoAnsweredReason = autoAnsweredReason; self.name = name
    }

    /// Duration-first rule (matches CallHistory's own status logic): any duration means connected.
    public var connected: Bool { duration > 0 }
    /// Missed = incoming, never connected, and not answered on another device (answered=1, duration=0).
    public var isMissedIncoming: Bool { !originated && !connected && !answered }
    public var isCellular: Bool { provider == "com.apple.Telephony" }
}

public struct AppleVoicemail: Sendable, Equatable {
    public var id: String           // record UUID (uppercase, dashed)
    public var callUUID: String?
    public var date: Date
    public var duration: Double
    public var number: String
    public var transcript: String?
    public var transcriptConfidence: Double?
    public var audioPath: String?
    public var isRead: Bool

    public init(id: String, callUUID: String?, date: Date, duration: Double, number: String, transcript: String?, transcriptConfidence: Double?, audioPath: String?, isRead: Bool) {
        self.id = id; self.callUUID = callUUID; self.date = date; self.duration = duration; self.number = number
        self.transcript = transcript; self.transcriptConfidence = transcriptConfidence; self.audioPath = audioPath; self.isRead = isRead
    }
}

/// Output of the content models for one voicemail.
public struct ContentJudgment: Codable, Sendable, Equatable {
    public var categoryProbs: [String: Double]
    public var callback: Double
    public var fraud: Double
    public var specific: Double
    public var automated: Double
    public var callerName: String?
    public var organization: String?
    public var summary: String?
    public var callbackNumber: String?
    public var deadline: String?

    public init(categoryProbs: [String: Double], callback: Double, fraud: Double, specific: Double, automated: Double, callerName: String? = nil, organization: String? = nil, summary: String? = nil, callbackNumber: String? = nil, deadline: String? = nil) {
        self.categoryProbs = categoryProbs; self.callback = callback; self.fraud = fraud; self.specific = specific; self.automated = automated
        self.callerName = callerName; self.organization = organization; self.summary = summary; self.callbackNumber = callbackNumber; self.deadline = deadline
    }

    public var topCategory: (String, Double) {
        categoryProbs.max { $0.value < $1.value }.map { ($0.key, $0.value) } ?? ("silent_or_unclear", 0)
    }
}

public struct Reputation: Codable, Sendable, Equatable {
    public var score: Double          // 0 (clean) … 1 (heavily reported)
    public var complaints: Int
    public var lastReported: Date?
    public var robocallShare: Double
    public var states: Int

    public init(score: Double = 0, complaints: Int = 0, lastReported: Date? = nil, robocallShare: Double = 0, states: Int = 0) {
        self.score = score; self.complaints = complaints; self.lastReported = lastReported; self.robocallShare = robocallShare; self.states = states
    }
    public static let clean = Reputation()
}

/// Everything known about the caller apart from message content.
public struct CallerContext: Sendable {
    public var contactName: String?
    public var appleTrustScore: Int?
    public var appleJunk: Bool
    public var outgoingCallsTo: Int       // times the user has called this number
    public var answeredCallsFrom: Int     // times the user picked up / talked
    public var callsLast24h: Int
    public var callsLast15m: Int
    public var reputation: Reputation
    public var userRule: Bucket?          // "always" rule from feedback (number)
    public var userRuleCategory: String?
    public var orgRule: Bucket?           // learned from feedback on organization
    public var blocked: Bool
    public var calendarMatch: String?     // title of a matching calendar event
    public var onlineReport: OnlineReport? = nil   // opt-in public lookup (RoboKiller)
    public var similarLabel: (Bucket, Double)? = nil  // most similar user-labelled message (bucket, similarity)
    public var similarCategory: String? = nil

    public init(contactName: String? = nil, appleTrustScore: Int? = nil, appleJunk: Bool = false, outgoingCallsTo: Int = 0, answeredCallsFrom: Int = 0, callsLast24h: Int = 1, callsLast15m: Int = 1, reputation: Reputation = .clean, userRule: Bucket? = nil, userRuleCategory: String? = nil, orgRule: Bucket? = nil, blocked: Bool = false, calendarMatch: String? = nil, onlineReport: OnlineReport? = nil) {
        self.contactName = contactName; self.appleTrustScore = appleTrustScore; self.appleJunk = appleJunk; self.outgoingCallsTo = outgoingCallsTo
        self.answeredCallsFrom = answeredCallsFrom; self.callsLast24h = callsLast24h; self.callsLast15m = callsLast15m; self.reputation = reputation
        self.userRule = userRule; self.userRuleCategory = userRuleCategory; self.orgRule = orgRule; self.blocked = blocked; self.calendarMatch = calendarMatch; self.onlineReport = onlineReport
    }

    public var isKnown: Bool { contactName != nil || (appleTrustScore ?? 0) >= 8 || outgoingCallsTo > 0 }
}

public struct Decision: Codable, Sendable, Equatable {
    public var bucket: Bucket
    public var category: String
    public var confidence: Double
    public var callbackRecommended: Bool
    public var callbackProbability: Double
    public var reasons: [String]
}
