import CryptoKit
import Foundation
import Security

struct DoubaoAndroidWaveSealedPayload: Sendable {
    let body: Data
    let headers: [String: String]
}

actor DoubaoAndroidWaveClient {
    private struct ActiveSession: Sendable {
        let key: Data
        let ticket: String
        let expiresAt: Date
    }

    private struct HandshakeResponse: Decodable {
        struct KeyShare: Decodable {
            let pubkey: String
        }

        let random: String
        let keyShare: KeyShare
        let ticket: String
        let ticketExp: Int

        enum CodingKeys: String, CodingKey {
            case random
            case keyShare = "key_share"
            case ticket
            case ticketExp = "ticket_exp"
        }
    }

    private let deviceID: String
    private let appID: Int
    private let userAgent: String
    private let urlSession: URLSession
    private let handshakeURL: URL
    private var activeSession: ActiveSession?

    init(
        deviceID: String,
        appID: Int,
        userAgent: String,
        urlSession: URLSession = .shared,
        handshakeURL: URL
    ) {
        self.deviceID = deviceID
        self.appID = appID
        self.userAgent = userAgent
        self.urlSession = urlSession
        self.handshakeURL = handshakeURL
    }

    func seal(_ plaintext: Data) async throws -> DoubaoAndroidWaveSealedPayload {
        let session = try await ensureSession()
        let nonce = try Self.randomData(count: 12)
        let ciphertext = try DoubaoChaCha20.crypt(
            key: session.key,
            nonce: nonce,
            data: plaintext
        )
        let stub = Insecure.MD5.hash(data: ciphertext)
            .map { String(format: "%02X", $0) }
            .joined()
        return DoubaoAndroidWaveSealedPayload(
            body: ciphertext,
            headers: [
                "x-tt-e-b": "1",
                "x-tt-e-t": session.ticket,
                "x-tt-e-p": nonce.base64EncodedString(),
                "x-ss-stub": stub
            ]
        )
    }

    func open(_ ciphertext: Data, nonce: Data) throws -> Data {
        guard let activeSession else {
            throw Self.error("Wave response arrived without an active session")
        }
        return try DoubaoChaCha20.crypt(
            key: activeSession.key,
            nonce: nonce,
            data: ciphertext
        )
    }

    private func ensureSession() async throws -> ActiveSession {
        if let activeSession, Date() < activeSession.expiresAt {
            return activeSession
        }
        return try await handshake()
    }

    private func handshake() async throws -> ActiveSession {
        let signingKey = P256.Signing.PrivateKey()
        let agreementKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: signingKey.rawRepresentation
        )
        let clientRandom = try Self.randomData(count: 32)
        let body: [String: Any] = [
            "version": 2,
            "random": clientRandom.base64EncodedString(),
            "app_id": String(appID),
            "did": deviceID,
            "key_shares": [[
                "curve": "secp256r1",
                "pubkey": agreementKey.publicKey.x963Representation.base64EncodedString()
            ]],
            "cipher_suites": [4097]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let signature = try signingKey.signature(for: bodyData).derRepresentation

        var request = URLRequest(url: handshakeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "x-tt-s-sign")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, operation: "Wave handshake")
        let payload = try JSONDecoder().decode(HandshakeResponse.self, from: data)
        guard let serverRandom = Data(base64Encoded: payload.random),
              let serverPublicData = Data(base64Encoded: payload.keyShare.pubkey),
              !payload.ticket.isEmpty else {
            throw Self.error("Wave handshake returned invalid key material")
        }
        let serverPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: serverPublicData
        )
        let sharedSecret = try agreementKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let salt = clientRandom + serverRandom
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("4e30514609050cd3".utf8),
            outputByteCount: 32
        )
        let key = symmetricKey.withUnsafeBytes { Data($0) }
        let ticketLifetime = payload.ticketExp > 60 ? payload.ticketExp : 600
        let session = ActiveSession(
            key: key,
            ticket: payload.ticket,
            expiresAt: Date().addingTimeInterval(TimeInterval(ticketLifetime - 60))
        )
        activeSession = session
        return session
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw error("Secure random generation failed")
        }
        return data
    }

    private static func validate(_ response: URLResponse, operation: String) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw error("\(operation) failed with HTTP \(status)", code: status)
        }
    }

    private static func error(_ description: String, code: Int = 1) -> NSError {
        NSError(
            domain: "Douvo.AndroidPersonalLexicon",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

enum DoubaoChaCha20 {
    static func crypt(
        key: Data,
        nonce: Data,
        data: Data,
        initialCounter: UInt32 = 0
    ) throws -> Data {
        guard key.count == 32, nonce.count == 12 else {
            throw NSError(
                domain: "Douvo.AndroidPersonalLexicon",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ChaCha20 requires a 32-byte key and 12-byte nonce"]
            )
        }

        let keyBytes = [UInt8](key)
        let nonceBytes = [UInt8](nonce)
        var output = [UInt8](data)
        var counter = initialCounter

        for offset in stride(from: 0, to: output.count, by: 64) {
            let block = block(key: keyBytes, nonce: nonceBytes, counter: counter)
            let count = min(64, output.count - offset)
            for index in 0..<count {
                output[offset + index] ^= block[index]
            }
            counter &+= 1
        }
        return Data(output)
    }

    private static func block(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        var state: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            word(key, 0), word(key, 4), word(key, 8), word(key, 12),
            word(key, 16), word(key, 20), word(key, 24), word(key, 28),
            counter, word(nonce, 0), word(nonce, 4), word(nonce, 8)
        ]
        let initial = state

        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        var output: [UInt8] = []
        output.reserveCapacity(64)
        for index in state.indices {
            let value = state[index] &+ initial[index]
            output.append(UInt8(truncatingIfNeeded: value))
            output.append(UInt8(truncatingIfNeeded: value >> 8))
            output.append(UInt8(truncatingIfNeeded: value >> 16))
            output.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        return output
    }

    private static func quarterRound(
        _ state: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int
    ) {
        state[a] &+= state[b]
        state[d] = rotateLeft(state[d] ^ state[a], by: 16)
        state[c] &+= state[d]
        state[b] = rotateLeft(state[b] ^ state[c], by: 12)
        state[a] &+= state[b]
        state[d] = rotateLeft(state[d] ^ state[a], by: 8)
        state[c] &+= state[d]
        state[b] = rotateLeft(state[b] ^ state[c], by: 7)
    }

    private static func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
