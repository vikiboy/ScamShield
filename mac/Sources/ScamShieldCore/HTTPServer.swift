import Foundation
import Network

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]   // lowercased keys
    public var body: Data
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var filePath: String? = nil      // stream a file (supports Range)

    public init(status: Int, headers: [String: String], body: Data, filePath: String? = nil) {
        self.status = status; self.headers = headers; self.body = body; self.filePath = filePath
    }

    public static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: data)
    }
    public static func encodable<T: Encodable>(_ v: T, status: Int = 200) -> HTTPResponse {
        let data = (try? Store.enc.encode(v)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: data)
    }
    public static func error(_ status: Int, _ msg: String) -> HTTPResponse { json(["error": msg], status: status) }
}

/// Small HTTP/1.1 server on loopback (Network.framework). One request per connection.
/// Exposed to the iPhone via `tailscale serve`, which terminates TLS.
public final class HTTPServer {
    let listener: NWListener
    let handler: (HTTPRequest) -> HTTPResponse
    let queue = DispatchQueue(label: "scamshield.http", attributes: .concurrent)

    /// Loopback by default. With `bonjourType`, listens on the local network and advertises
    /// itself (used for the direct Wi-Fi path to the iPhone app; every request is token-checked).
    public init(port: UInt16, bonjourType: String? = nil, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let bonjourType {
            params.includePeerToPeer = false
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: "ScamShield", type: bonjourType)
        } else {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
        }
        self.handler = handler
    }

    public func start(onState: @escaping (String) -> Void) {
        listener.stateUpdateHandler = { onState("\($0)") }
        // Strong capture on purpose: a started server lives for the life of the process
        // (a weak capture let an unreferenced server be freed and silently ignore connections).
        listener.newConnectionHandler = { conn in self.accept(conn) }
        listener.start(queue: queue)
    }

    func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                let resp = self.handler(req)
                self.send(resp, req: req, on: conn)
            } else if done || err != nil || buf.count > 8 << 20 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard buf.count - bodyStart >= len else { return nil }
        let body = buf.subdata(in: bodyStart..<(bodyStart + len))
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        let path = comps?.percentEncodedPath.removingPercentEncoding ?? target
        return HTTPRequest(method: String(parts[0]), path: path, query: q, headers: headers, body: body)
    }

    func send(_ r: HTTPResponse, req: HTTPRequest, on conn: NWConnection) {
        var resp = r
        var status = resp.status
        if let fp = resp.filePath {
            guard let fh = FileHandle(forReadingAtPath: fp), let size = try? FileManager.default.attributesOfItem(atPath: fp)[.size] as? Int else {
                resp = .error(404, "not found"); status = 404
                return write(resp, status: status, req: req, on: conn)
            }
            defer { try? fh.close() }
            var start = 0, end = size - 1
            if let range = req.headers["range"], range.hasPrefix("bytes=") {
                let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                if spec.count == 2 {
                    if let s = Int(spec[0]) { start = s; if let e = Int(spec[1]) { end = min(e, size - 1) } }
                    else if let suffix = Int(spec[1]) { start = max(0, size - suffix) }
                }
                status = 206
                resp.headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            }
            if start > end || start >= size { resp = .error(416, "bad range"); return write(resp, status: 416, req: req, on: conn) }
            try? fh.seek(toOffset: UInt64(start))
            resp.body = fh.readData(ofLength: end - start + 1)
            resp.headers["Accept-Ranges"] = "bytes"
        }
        write(resp, status: status, req: req, on: conn)
    }

    func write(_ resp: HTTPResponse, status: Int, req: HTTPRequest, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if req.method != "HEAD" { out.append(resp.body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
