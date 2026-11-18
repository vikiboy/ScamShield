import Foundation
import CryptoKit

/// Clients for the two local model services (both bound to 127.0.0.1):
///  - decider: Kev-4B, a System One-style decision model (TypeSafe-compatible /v1/systemone API)
///    returning calibrated probabilities for typed questions.
///  - writer: a small instruct model (Qwen3.5-4B, MLX) used only to extract names and write a
///    one-line summary. It never makes the routing decision.
public final class Brain {
    let config: Config
    let questions: [String: Any]
    let extractSystem: String
    let session: URLSession
    /// Changes whenever the decision questions or extraction prompt change.
    public let promptFingerprint: String

    public enum BrainError: Error { case unavailable(String), badResponse(String) }

    public init(config: Config, promptsDir: URL) throws {
        self.config = config
        let q = try Data(contentsOf: promptsDir.appendingPathComponent("questions.json"))
        questions = (try JSONSerialization.jsonObject(with: q) as? [String: Any]) ?? [:]
        extractSystem = try String(contentsOf: promptsDir.appendingPathComponent("extract_system.txt"), encoding: .utf8)
        promptFingerprint = String(SHA256.hash(data: q + Data(extractSystem.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined())
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c)
    }

    func post(_ urlString: String, _ body: [String: Any]) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(BrainError.unavailable(urlString))
        session.dataTask(with: req) { data, resp, err in
            if let err { result = .failure(BrainError.unavailable("\(urlString): \(err.localizedDescription)")) }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(BrainError.badResponse("\(urlString): HTTP \(http.statusCode) \(String(decoding: data ?? Data(), as: UTF8.self).prefix(200))"))
            } else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        guard let obj = try JSONSerialization.jsonObject(with: try result.get()) as? [String: Any] else { throw BrainError.badResponse(urlString) }
        return obj
    }

    public func judge(transcript: String) throws -> ContentJudgment {
        let state = ["voicemail": ["transcript": transcript]]
        let stateJSON = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        let resp = try post(config.deciderURL, ["model": "kev-latest", "state": stateJSON, "questions": questions])
        guard let answers = resp["answers"] as? [String: Any],
              let cat = answers["category"] as? [String: Any],
              let probs = cat["probabilities"] as? [String: Double] else { throw BrainError.badResponse("decider: \(resp)") }
        func noul(_ k: String) -> Double { ((answers[k] as? [String: Any])?["noul"] as? Double) ?? 0.5 }
        var j = ContentJudgment(categoryProbs: probs, callback: noul("callback"), fraud: noul("fraud"),
                                specific: noul("specific"), automated: noul("automated"))
        // Summary/extraction is best-effort: a routing decision never waits on it failing.
        if let x = try? extract(transcript: transcript) {
            j.callerName = x["caller_name"]; j.organization = x["organization"]; j.summary = x["summary"]
            j.callbackNumber = x["callback_number"]; j.deadline = x["deadline"]
        }
        return j
    }

    func extract(transcript: String) throws -> [String: String] {
        let body: [String: Any] = [
            "model": config.writerModel, "temperature": 0, "max_tokens": 220,
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "system", "content": extractSystem], ["role": "user", "content": "Transcript:\n" + transcript]],
        ]
        let resp = try post(config.writerURL, body)
        guard let content = ((resp["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String else {
            throw BrainError.badResponse("writer")
        }
        return Self.parseExtraction(content)
    }

    /// Tolerant JSON parse: strips code fences / leading prose, keeps only string values.
    public static func parseExtraction(_ content: String) -> [String: String] {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String, !s.isEmpty, s.lowercased() != "null" { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }

    public func health() -> [String: String] {
        var out: [String: String] = [:]
        for (name, url) in [("decider", config.deciderURL), ("writer", config.writerURL)] {
            let base = URL(string: url)!
            let models = URL(string: "/v1/models", relativeTo: base)!
            var req = URLRequest(url: models); req.timeoutInterval = 3
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            session.dataTask(with: req) { _, resp, _ in ok = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 4)
            out[name] = ok ? "ok" : "down"
        }
        return out
    }
}
