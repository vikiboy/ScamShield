import Foundation

/// Date and number formatting shared by the list, detail and settings screens
/// (same rules as web/app.js).
enum Format {
    /// Row timestamp: "Now", "12m ago", "3:42 PM", "Yesterday", "Mon", "Nov 2".
    static func rowTime(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "Now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        let days = dayDiff(date, now: now, calendar: calendar)
        if days == 0 { return date.formatted(date: .omitted, time: .shortened) }
        if days == 1 { return "Yesterday" }
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return shortDate(date, now: now, calendar: calendar)
    }

    /// Long form: "Today at 3:42 PM", "Monday, Nov 16 at 3:42 PM".
    static func longDate(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "Unknown time" }
        let days = dayDiff(date, now: now, calendar: calendar)
        let time = date.formatted(date: .omitted, time: .shortened)
        if days == 0 { return "Today at \(time)" }
        if days == 1 { return "Yesterday at \(time)" }
        let day = shortDate(date, now: now, calendar: calendar)
        let weekday = days < 7 ? date.formatted(.dateTime.weekday(.wide)) + ", " : ""
        return "\(weekday)\(day) at \(time)"
    }

    /// Settings-style relative time: "Just now", "5 minutes ago", "yesterday".
    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never" }
        if abs(now.timeIntervalSince(date)) < 45 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    static func duration(_ seconds: Double?) -> String {
        let total = max(0, Int((seconds ?? 0).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return "\(Int((value * 100).rounded()))%"
    }

    static func dayDiff(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: start, to: today).day ?? 0
    }

    private static func shortDate(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

extension Array where Element == Item {
    /// "Today", "Yesterday", "Earlier" groups in list order, skipping empty ones.
    func groupedByDay(now: Date = .now) -> [(title: String, items: [Item])] {
        var groups: [(title: String, items: [Item])] = [("Today", []), ("Yesterday", []), ("Earlier", [])]
        for item in self {
            let days = item.date.map { Format.dayDiff($0, now: now) } ?? 99
            groups[days <= 0 ? 0 : days == 1 ? 1 : 2].items.append(item)
        }
        return groups.filter { !$0.items.isEmpty }
    }
}
