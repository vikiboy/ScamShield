import Foundation
import CryptoKit

/// Standards Web Push (RFC 8030) with VAPID (RFC 8292) and aes128gcm payload encryption
/// (RFC 8291). iOS Home Screen web apps receive these through Apple's push service; the
/// payload is end-to-end encrypted to the phone, so Apple's relay cannot read it.
/// No developer account is needed.
public final class WebPush {
    let key: P256.Signing.PrivateKey
    let subject: String
    let session = URLSession(configuration: .ephemeral)

    public init(keyFile: URL, subject: String) throws {
        if let raw = try? Data(contentsOf: keyFile), let k = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            key = k
        } else {
            key = P256.Signing.PrivateKey()
            try key.rawRepresentation.write(to: keyFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        }
        self.subject = subject
    }

    public var publicKeyBase64URL: String { key.publicKey.x963Representation.base64URL }

    public struct Subscription: Codable {
        public var endpoint: String
        public var keys: Keys
        public struct Keys: Codable { public var p256dh: String; public var auth: String }
    }

    public enum Outcome { case sent, gone, failed(String) }

    public func send(_ payload: Data, to sub: Subscription, ttl: Int = 86400, urgency: String = "high") -> Outcome {
        guard let url = URL(string: sub.endpoint), let host = url.host, let scheme = url.scheme else { return .failed("bad endpoint") }
        do {
            let body = try Self.encrypt(payload, p256dh: sub.keys.p256dh, auth: sub.keys.auth)
            let jwt = try vapidJWT(audience: "\(scheme)://\(host)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("vapid t=\(jwt), k=\(publicKeyBase64URL)", forHTTPHeaderField: "Authorization")
            req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(ttl), forHTTPHeaderField: "TTL")
            req.setValue(urgency, forHTTPHeaderField: "Urgency")
            let sem = DispatchSemaphore(value: 0)
            var outcome: Outcome = .failed("timeout")
            session.dataTask(with: req) { data, resp, err in
                if let err { outcome = .failed(err.localizedDescription) }
                else if let http = resp as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200...299: outcome = .sent
                    case 404, 410: outcome = .gone
                    default: outcome = .failed("HTTP \(http.statusCode) \(String(decoding: data ?? Data(), as: UTF8.self).prefix(200))")
                    }
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 30)
            return outcome
        } catch { return .failed("\(error)") }
    }

    func vapidJWT(audience: String) throws -> String {
        let header = Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8).base64URL
        let claims: [String: Any] = ["aud": audience, "exp": Int(Date().timeIntervalSince1970) + 12 * 3600, "sub": subject]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let input = "\(header).\(payload)"
        let sig = try key.signature(for: Data(input.utf8))
        return "\(input).\(sig.rawRepresentation.base64URL)"
    }

    public enum CryptoError: Error { case badKey }

    /// RFC 8291 encryption, single record. Exposed for tests.
    public static func encrypt(_ plaintext: Data, p256dh: String, auth: String,
                               ephemeral: P256.KeyAgreement.PrivateKey = .init(), salt: Data? = nil) throws -> Data {
        guard let uaPubRaw = Data(base64URL: p256dh), let authSecret = Data(base64URL: auth) else { throw CryptoError.badKey }
        let uaPub = try P256.KeyAgreement.PublicKey(x963Representation: uaPubRaw)
        let asPubRaw = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: uaPub)
        let sharedData = shared.withUnsafeBytes { Data($0) }

        // IKM = HKDF(salt=auth, ikm=ecdh, info="WebPush: info\0"||ua_pub||as_pub, 32)
        let keyInfo = Data("WebPush: info\u{0}".utf8) + uaPubRaw + asPubRaw
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedData), salt: authSecret, info: keyInfo, outputByteCount: 32)

        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })

        var padded = plaintext; padded.append(0x02)   // last-record delimiter
        let sealed = try AES.GCM.seal(padded, using: cek, nonce: nonce)
        var header = Data()
        header.append(salt)
        var rs = UInt32(4096).bigEndian
        header.append(Data(bytes: &rs, count: 4))
        header.append(UInt8(asPubRaw.count))
        header.append(asPubRaw)
        return header + sealed.ciphertext + sealed.tag
    }

    /// RFC 8291 decryption (receiver side) — used only by tests to verify `encrypt`.
    public static func decrypt(_ body: Data, uaPrivate: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        let b = [UInt8](body)
        let salt = Data(b[0..<16])
        let idlen = Int(b[20])
        let asPubRaw = Data(b[21..<(21 + idlen)])
        let ct = Data(b[(21 + idlen)...])
        let asPub = try P256.KeyAgreement.PublicKey(x963Representation: asPubRaw)
        let shared = try uaPrivate.sharedSecretFromKeyAgreement(with: asPub).withUnsafeBytes { Data($0) }
        let keyInfo = Data("WebPush: info\u{0}".utf8) + uaPrivate.publicKey.x963Representation + asPubRaw
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: auth, info: keyInfo, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) }),
                                        ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        var plain = try AES.GCM.open(box, using: cek)
        while let last = plain.last, last == 0 { plain.removeLast() }
        if plain.last == 0x02 { plain.removeLast() }
        return plain
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
