import Foundation

/// Explicit, auditable decision policy. The models supply judgments (probabilities);
/// this code owns what happens with them. Safety rules:
///  - Contacts, numbers you have called, and calendar matches never land in Scams.
///  - Content that looks even moderately legitimate is never sent to Scams (at worst Review).
///  - A missed call with no message and no strong evidence goes to Review, not Scams.
public enum Classifier {
    // Kev category → (bucket family, API category)
    public static let legitMap: [String: String] = [
        "personal": "personal",
        "appointment_or_medical": "appointment",
        "delivery_or_service": "delivery",
        "work_or_recruiter": "recruiter",
        "account_legit": "business",
    ]
    public static let scamMap: [String: String] = [
        "fraud_impersonation": "fraud",
        "loan_or_debt_offer": "loan_offer",
        "sales_telemarketing": "telemarketing",
        "robocall_other": "robocall",
    ]

    public struct Thresholds: Codable, Sendable, Equatable {
        public var legitAttention = 0.45     // P(legit) at/above which content goes to Attention
        public var legitNeverScam = 0.20     // P(legit) at/above which content can never be auto-Scam…
        /// …unless no single legit category is plausible: the model spreads ~4–5% "background"
        /// probability over each legit category, so a summed floor alone blocks obvious robocalls.
        /// On the user's 42 real voicemails the top legit category was ≤0.09 for every robocall and
        /// ≥0.38 for every real caller.
        public var legitTopMaxForScam = 0.15
        public var legitSumHardFloor = 0.35
        /// Word-shingle similarity to a message the user already labelled that counts as "same script".
        public var similarToLabelled = 0.5
        public var scamContent = 0.55        // P(scam family) needed for Scams
        public var robocallAutomated = 0.70
        public var reputationScam = 0.60     // reputation score that alone (with weak legit) means Scams
        public var reputationNoMessageScam = 0.50
        public init() {}
    }

    public static func decide(context ctx: CallerContext, voicemail: AppleVoicemail?, judgment j: ContentJudgment?, thresholds t: Thresholds = Thresholds()) -> Decision {
        var reasons: [String] = []
        let rep = ctx.reputation
        if rep.complaints > 0 {
            var s = "Reported \(rep.complaints)× to FTC/FCC"
            if let d = rep.lastReported { s += " (last \(shortDate(d)))" }
            reasons.append(s)
        }

        // 1. Explicit user rules win.
        if let rule = ctx.userRule {
            let cat = ctx.userRuleCategory ?? (rule == .scam ? "spam_other" : rule == .attention ? "callback_request" : "unclear")
            return Decision(bucket: rule, category: cat, confidence: 1, callbackRecommended: rule == .attention,
                            callbackProbability: rule == .attention ? 1 : 0, reasons: ["You set a rule for this number"] + reasons)
        }
        if ctx.blocked {
            return Decision(bucket: .scam, category: "blocked", confidence: 1, callbackRecommended: false, callbackProbability: 0,
                            reasons: ["On your ScamShield blocklist"] + reasons)
        }

        // 2. People you know.
        if ctx.isKnown {
            if let n = ctx.contactName { reasons.insert("In your contacts (\(n))", at: 0) }
            else if ctx.outgoingCallsTo > 0 { reasons.insert("You've called this number before", at: 0) }
            else { reasons.insert("iPhone recognizes this caller", at: 0) }
            var cat = "known_contact"
            if let j, let legit = legitMap[j.topCategory.0] { cat = legit }
            return Decision(bucket: .attention, category: cat, confidence: 0.99, callbackRecommended: true,
                            callbackProbability: max(0.8, j?.callback ?? 0.8), reasons: reasons)
        }
        let scamMass = j.map { jj in scamMap.keys.reduce(0) { $0 + (jj.categoryProbs[$1] ?? 0) } } ?? 0
        if let ev = ctx.calendarMatch, scamMass < 0.5 {   // a calendar hit never overrides scam-like content
            reasons.insert("Matches your calendar: \(ev)", at: 0)
            let cat = j.flatMap { legitMap[$0.topCategory.0] } ?? "appointment"
            return Decision(bucket: .attention, category: cat, confidence: 0.9, callbackRecommended: true,
                            callbackProbability: max(0.7, j?.callback ?? 0.7), reasons: reasons)
        }

        // 3. We have message content.
        if let j {
            let pL = legitMap.keys.reduce(0) { $0 + (j.categoryProbs[$1] ?? 0) }
            let pS = scamMap.keys.reduce(0) { $0 + (j.categoryProbs[$1] ?? 0) }
            let topLegit = legitMap.keys.max { (j.categoryProbs[$0] ?? 0) < (j.categoryProbs[$1] ?? 0) }!
            let topScam = scamMap.keys.max { (j.categoryProbs[$0] ?? 0) < (j.categoryProbs[$1] ?? 0) }!

            // Org rules key on a caller-claimed name, so they only nudge within the safety floors.
            if ctx.orgRule == .scam && pL < t.legitNeverScam {
                return Decision(bucket: .scam, category: scamMap[topScam]!, confidence: 0.95, callbackRecommended: false, callbackProbability: j.callback,
                                reasons: ["You marked this organization as unwanted"] + reasons)
            }
            if (ctx.orgRule == .attention && pS < 0.5) || pL >= t.legitAttention {
                let cat = legitMap[topLegit]!
                reasons.insert(contentReason(cat), at: 0)
                if ctx.orgRule == .attention { reasons.insert("You marked this organization as important", at: 0) }
                if j.specific >= 0.5 { reasons.append("Refers to something specific to you") }
                let strongLegit = ["personal", "appointment", "recruiter", "delivery"].contains(cat)
                let cb = j.callback >= 0.2 || strongLegit || (j.callbackNumber != nil && j.callback >= 0.1)
                return Decision(bucket: .attention, category: cat, confidence: max(pL, ctx.orgRule == .attention ? 0.9 : 0),
                                callbackRecommended: cb, callbackProbability: j.callback, reasons: reasons)
            }
            let maxL = legitMap.keys.map { j.categoryProbs[$0] ?? 0 }.max() ?? 0
            // Learned from corrections: nearly the same script as a message the user labelled.
            if let (b, sim) = ctx.similarLabel, sim >= t.similarToLabelled {
                if b == .scam && maxL < 0.3 {
                    return Decision(bucket: .scam, category: ctx.similarCategory ?? scamMap[topScam]!, confidence: sim, callbackRecommended: false,
                                    callbackProbability: j.callback, reasons: ["Nearly identical to a message you marked as unwanted"] + reasons)
                }
                if b == .attention && pS < 0.5 {
                    return Decision(bucket: .attention, category: ctx.similarCategory ?? legitMap[topLegit]!, confidence: sim, callbackRecommended: true,
                                    callbackProbability: j.callback, reasons: ["Similar to a message you marked as important"] + reasons)
                }
            }
            let noPlausibleLegit = maxL < t.legitTopMaxForScam && pL < t.legitSumHardFloor
            if pL < t.legitNeverScam || noPlausibleLegit {
                if pS >= t.scamContent {
                    let cat = scamMap[topScam]!
                    reasons.insert(contentReason(cat), at: 0)
                    if j.fraud >= 0.6 { reasons.append("Shows signs of fraud (pressure, too-good-to-be-true)") }
                    if j.automated >= 0.7 { reasons.append("Pre-recorded message") }
                    return Decision(bucket: .scam, category: cat, confidence: pS, callbackRecommended: false, callbackProbability: j.callback, reasons: reasons)
                }
                if j.automated >= t.robocallAutomated && j.specific < 0.3 {
                    reasons.insert("Generic pre-recorded message", at: 0)
                    let cat = (j.categoryProbs[topScam] ?? 0) >= 0.2 ? scamMap[topScam]! : "robocall"
                    return Decision(bucket: .scam, category: cat, confidence: (j.automated + pS) / 2, callbackRecommended: false, callbackProbability: j.callback, reasons: reasons)
                }
                if rep.score >= t.reputationScam {
                    return Decision(bucket: .scam, category: rep.robocallShare > 0.5 ? "robocall" : "spam_other", confidence: rep.score,
                                    callbackRecommended: false, callbackProbability: j.callback, reasons: reasons)
                }
            }
            reasons.insert("Message is ambiguous — please take a look", at: 0)
            return Decision(bucket: .review, category: "unclear", confidence: 1 - max(pL, pS), callbackRecommended: j.callback >= 0.5,
                            callbackProbability: j.callback, reasons: reasons)
        }

        // 4. No message content.
        let appleJunk = ctx.appleJunk
        if appleJunk {
            return Decision(bucket: .scam, category: "spam_other", confidence: 0.85, callbackRecommended: false, callbackProbability: 0,
                            reasons: ["iPhone flagged this call as spam"] + reasons)
        }
        if rep.score >= t.reputationNoMessageScam {
            return Decision(bucket: .scam, category: rep.robocallShare > 0.5 ? "robocall" : "spam_other", confidence: rep.score,
                            callbackRecommended: false, callbackProbability: 0, reasons: reasons)
        }
        if let online = ctx.onlineReport {
            if let cat = online.scamCategory {
                return Decision(bucket: .scam, category: cat, confidence: online.blocked ? 0.9 : 0.75, callbackRecommended: false,
                                callbackProbability: 0, reasons: [online.summaryLine] + reasons)
            }
            reasons.append(online.summaryLine)
        }
        if ctx.callsLast15m >= 2 && rep.score < 0.2 {
            return Decision(bucket: .attention, category: "repeated_caller", confidence: 0.6, callbackRecommended: true, callbackProbability: 0.6,
                            reasons: ["Called \(ctx.callsLast15m)× within 15 minutes — may be urgent"] + reasons)
        }
        if ctx.answeredCallsFrom > 0 {
            return Decision(bucket: .attention, category: "known_contact", confidence: 0.7, callbackRecommended: true, callbackProbability: 0.6,
                            reasons: ["You've spoken with this number before"] + reasons)
        }
        let why = voicemail != nil ? "Voicemail has no transcript yet" : "No voicemail left"
        return Decision(bucket: .review, category: voicemail != nil ? "unclear" : "no_message", confidence: 0.5,
                        callbackRecommended: false, callbackProbability: 0, reasons: [why] + reasons)
    }

    static func contentReason(_ cat: String) -> String {
        switch cat {
        case "personal": return "Sounds like a personal message"
        case "appointment": return "About an appointment or medical care"
        case "delivery": return "About a delivery or service visit"
        case "recruiter": return "About a job or work matter"
        case "business": return "About one of your accounts"
        case "fraud": return "Looks like a scam or impersonation"
        case "loan_offer": return "Unsolicited loan / debt offer"
        case "telemarketing": return "Unsolicited sales pitch"
        case "robocall": return "Automated robocall"
        default: return cat
        }
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
}
