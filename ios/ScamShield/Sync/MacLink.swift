import Foundation
import Network
import os

/// Direct Wi-Fi path to the Mac agent: finds it via Bonjour (`_scamshield._tcp`) and fetches the
/// current inbox over HTTP with the shared token built into this app. Used first on every refresh;
/// when the Mac isn't on the same network, the app falls back to the iCloud Drive folder.
enum MacLink {
    static let serviceType = "_scamshield._tcp"
    private static let log = Logger(subsystem: "local.scamshield", category: "maclink")

    static var token: String? {
        guard let t = Bundle.main.object(forInfoDictionaryKey: "ScamShieldLANToken") as? String, t.count >= 32 else { return nil }
        return t
    }

    /// The inbox JSON from the Mac, or nil if the Mac can't be reached quickly.
    static func fetchInbox(timeout: TimeInterval = 4) async -> Data? {
        guard let token else { return nil }
        guard let endpoint = await findMac(timeout: timeout) else { return nil }
        let data = await request(endpoint: endpoint, path: "/inbox", token: token, timeout: timeout + 6)
        log.info("Wi-Fi fetch \(data == nil ? "failed" : "ok", privacy: .public)")
        return data
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<T, Never>
        init(_ c: CheckedContinuation<T, Never>) { continuation = c }
        func resume(_ value: T) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(returning: value)
        }
    }

    private static func findMac(timeout: TimeInterval) async -> NWEndpoint? {
        await withCheckedContinuation { (c: CheckedContinuation<NWEndpoint?, Never>) in
            let once = Once(c)
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                if let first = results.first { once.resume(first.endpoint); browser.cancel() }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { once.resume(nil); browser.cancel() }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil); browser.cancel() }
        }
    }

    private static func request(endpoint: NWEndpoint, path: String, token: String, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            let once = Once(c)
            let conn = NWConnection(to: endpoint, using: .tcp)
            let buffer = Buffer()
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if complete || error != nil {
                        once.resume(parse(buffer.data)); conn.cancel()
                    } else { receive() }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET \(path) HTTP/1.1\r\nHost: scamshield\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in receive() })
                case .failed, .cancelled:
                    once.resume(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil); conn.cancel() }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Minimal HTTP/1.1 response parse: status 200 → body.
    static func parse(_ raw: Data) -> Data? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<sep.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else { return nil }
        return raw[sep.upperBound...].isEmpty ? nil : Data(raw[sep.upperBound...])
    }
}
