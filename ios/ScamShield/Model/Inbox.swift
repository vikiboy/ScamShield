import Foundation

/// inbox.json, written by the Mac into the sync folder (docs/SYNC.md).
struct Inbox: Decodable, Sendable {
    struct Mac: Decodable, Sendable {
        var lastCallSeen: Date?
        var lastIngest: Date?
        var lastVoicemailSeen: Date?
        var models: ModelHealth?
    }

    var version: Int?
    var generatedAt: Date?
    var mac: Mac?
    var items: [Item]
    /// Entries that were present but could not be read (unknown bucket, missing id, …).
    var skippedItems: Int

    private enum CodingKeys: String, CodingKey { case version, generatedAt, mac, items }

    init(version: Int? = 1, generatedAt: Date?, mac: Mac? = nil, items: [Item]) {
        self.version = version
        self.generatedAt = generatedAt
        self.mac = mac
        self.items = items
        self.skippedItems = 0
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
        mac = try? c.decodeIfPresent(Mac.self, forKey: .mac)
        // One unreadable item must not blank the whole list.
        let lossy = try c.decodeIfPresent([Lossy<Item>].self, forKey: .items) ?? []
        items = lossy.compactMap(\.value)
        skippedItems = lossy.count - items.count
    }

    static func decode(_ data: Data) throws -> Inbox {
        try JSON.decoder.decode(Inbox.self, from: data)
    }
}

/// `mac.models` is `"ok"` in SYNC.md but `{"decider": "ok", "writer": "ok"}` in the HTTP status
/// API; accept either.
enum ModelHealth: Decodable, Sendable, Equatable {
    case summary(String)
    case detail([String: String])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            self = .summary(text)
        } else {
            self = .detail(try c.decode([String: String].self))
        }
    }

    var isOK: Bool {
        switch self {
        case .summary(let value): value == "ok"
        case .detail(let values): !values.isEmpty && values.values.allSatisfy { $0 == "ok" }
        }
    }

    var description: String {
        switch self {
        case .summary(let value): value == "ok" ? "Running" : value.capitalized
        case .detail(let values):
            values.allSatisfy { $0.value == "ok" }
                ? "Running"
                : values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        }
    }
}

private struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// One user action, written by the app as corrections/<id>.json (docs/SYNC.md).
/// Optional fields are omitted from the JSON when nil, matching the contract examples.
struct Correction: Codable, Hashable, Identifiable, Sendable {
    enum Action: String, Codable, Sendable {
        case label, done, block
    }

    var id: String
    var itemId: String
    var action: Action
    var bucket: Bucket?
    var category: String?
    var applyToNumber: Bool?
    var done: Bool?
    var number: String?
    var block: Bool?
    var at: Date

    static func label(itemId: String, bucket: Bucket, category: String, applyToNumber: Bool, at: Date = .now) -> Correction {
        Correction(id: newID(), itemId: itemId, action: .label, bucket: bucket, category: category,
                   applyToNumber: applyToNumber, at: at)
    }

    static func done(itemId: String, done: Bool, at: Date = .now) -> Correction {
        Correction(id: newID(), itemId: itemId, action: .done, done: done, at: at)
    }

    static func block(itemId: String, number: String, block: Bool, at: Date = .now) -> Correction {
        Correction(id: newID(), itemId: itemId, action: .block, number: number, block: block, at: at)
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }

    func encoded() throws -> Data {
        try JSON.encoder.encode(self)
    }
}

enum JSON {
    /// The Mac writes plain ISO-8601 (`2026-11-17T17:40:00Z`); accept fractional seconds too.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO-8601 date: \(text)")
            }
            return date
        }
        return decoder
    }()

    /// Writes dates without fractional seconds, which is what the Mac's `.iso8601` decoder accepts.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
