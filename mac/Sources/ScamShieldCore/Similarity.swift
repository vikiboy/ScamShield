import Foundation

/// Script similarity for learning from corrections: robocall campaigns reuse near-identical
/// wording from rotating numbers, so word 3-shingle Jaccard similarity recognizes "the same
/// message" even when transcription differs slightly.
public enum Similarity {
    public static func shingles(_ text: String, n: Int = 3) -> Set<String> {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= n else { return Set(words) }
        return Set((0...(words.count - n)).map { words[$0..<($0 + n)].joined(separator: " ") })
    }
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
