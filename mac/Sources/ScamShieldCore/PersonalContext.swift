import Foundation
import Contacts
import EventKit

/// On-device personal context: Contacts (who you know) and Calendar (what you're expecting).
/// Nothing here leaves the Mac.
public final class PersonalContext: @unchecked Sendable {
    let contactStore = CNContactStore()
    let eventStore = EKEventStore()
    let useContacts: Bool
    let useCalendar: Bool
    let log: (String) -> Void
    private var names: [String: String] = [:]     // last-10-digit key → display name
    private var loadedAt: Date = .distantPast
    private let lock = NSLock()
    public private(set) var contactsStatus = "unknown"
    public private(set) var calendarStatus = "unknown"

    public init(useContacts: Bool, useCalendar: Bool, log: @escaping (String) -> Void) {
        self.useContacts = useContacts; self.useCalendar = useCalendar; self.log = log
    }

    public func requestAccess() {
        let sem = DispatchSemaphore(value: 0)
        if useContacts {
            contactStore.requestAccess(for: .contacts) { ok, err in
                self.contactsStatus = ok ? "granted" : "denied"
                if let err { self.log("contacts access: \(err.localizedDescription)") }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 120)
        } else { contactsStatus = "off" }
        if useCalendar {
            eventStore.requestFullAccessToEvents { ok, err in
                self.calendarStatus = ok ? "granted" : "denied"
                if let err { self.log("calendar access: \(err.localizedDescription)") }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 120)
        } else { calendarStatus = "off" }
        reloadContacts()
    }

    public func reloadContacts() {
        guard useContacts, CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        var map: [String: String] = [:]
        let keys = [CNContactPhoneNumbersKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys)
        do {
            try contactStore.enumerateContacts(with: req) { c, _ in
                var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = c.nickname.isEmpty ? c.organizationName : c.nickname }
                guard !name.isEmpty else { return }
                for p in c.phoneNumbers {
                    let k = PhoneNumber.key(p.value.stringValue)
                    if k.count >= 7 { map[k] = name }
                }
            }
            lock.lock(); names = map; loadedAt = Date(); lock.unlock()
            log("contacts: \(map.count) numbers indexed")
        } catch { log("contacts: \(error.localizedDescription)") }
    }

    public func contactName(for number: String) -> String? {
        lock.lock(); let stale = Date().timeIntervalSince(loadedAt) > 3600; lock.unlock()
        if stale { reloadContacts() }
        lock.lock(); defer { lock.unlock() }
        return names[PhoneNumber.key(number)]
    }

    static let stop: Set<String> = ["the", "and", "from", "with", "office", "calling", "call", "this", "your", "health", "center",
                                    "services", "service", "group", "inc", "llc", "company", "team", "department", "scheduling"]

    /// Finds an event near `date` whose title/location/notes mention the caller's organization,
    /// name, or phone number.
    public func calendarMatch(organization: String?, callerName: String?, number: String, around date: Date) -> String? {
        guard useCalendar, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        func toks(_ s: String?) -> [String] {
            (s ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count >= 4 && !Self.stop.contains($0) }
        }
        // Organization: any distinctive word. Person: every word of the full name (a lone
        // first or last name like "Houston" matches far too many events).
        let orgTokens = toks(organization)
        let nameTokens = toks(callerName)
        let tokens = Set(orgTokens)
        let digits = PhoneNumber.key(number)
        guard !tokens.isEmpty || nameTokens.count >= 2 || digits.count == 10 else { return nil }
        let pred = eventStore.predicateForEvents(withStart: date.addingTimeInterval(-3 * 86400), end: date.addingTimeInterval(30 * 86400), calendars: nil)
        for ev in eventStore.events(matching: pred) {
            let hay = [ev.title, ev.location, ev.notes].compactMap { $0 }.joined(separator: " ").lowercased()
            let hayDigits = hay.filter(\.isNumber)
            let nameHit = nameTokens.count >= 2 && nameTokens.allSatisfy { hay.contains($0) }
            if (digits.count == 10 && hayDigits.contains(digits)) || tokens.contains(where: { hay.contains($0) }) || nameHit {
                let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"
                return "\(ev.title ?? "Event") (\(f.string(from: ev.startDate)))"
            }
        }
        return nil
    }
}
