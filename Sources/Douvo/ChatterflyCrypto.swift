import CommonCrypto
import Foundation
import Security

enum ChatterflyCryptoError: LocalizedError {
    case invalidPublicKey
    case invalidKeyLength
    case randomFailure(OSStatus)
    case rsaFailure
    case aesFailure(status: CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "Chatterfly RSA public key is invalid"
        case .invalidKeyLength:
            return "Chatterfly AES key or IV has an invalid length"
        case let .randomFailure(status):
            return "Unable to generate Chatterfly AES material (status=\(status))"
        case .rsaFailure:
            return "Unable to RSA-encrypt Chatterfly AES material"
        case let .aesFailure(status):
            return "Unable to AES-encrypt Chatterfly payload (status=\(status))"
        }
    }
}

struct ChatterflyCrypto {
    // Extracted from SGSSERSAAESEncryptor in the installed Chatterfly build.
    static let rsaPublicKeyBase64 = [
        "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvCokx3cIJJJlDaYxvkWY5zUdxVKozeuXuqCOz65FxY/JseXDoVyEv/efn/amvcSFNodZT8svyevqLoPGR/vPMo6HBqN+FVqt35i/9Er3+fnmuHRXesU1ptgri4qCLXbEon8aUvYc82DXaz20y3fDgye326bARKkp2pLQcJtRmdydRSWvcBLDlHw66CIMx7X4+v+kH6w1Jxk1dA2Z2vDbAtY6kYTNQwPUeFV17HB9Vci1VwHOxUkBhmtYQP/dMBlORupO7LJ7NSwbHnZm/y9SEwKpGqZiUUgOzJA1xnKc7dTP57Spz4JXTi0Z1UsYZRliWO/tOTEYRdjzAn05kiemxwV8iX1CljkCFn1wOpMlhUHh3IY8uU+T0NXLLOt00HzdkCRkddt8eSHaOnZemUZV4oyW0d9wV8cwAMXCq+rVeT06GrXDLfx70Uk0pMr9g/91dLUShgLBCPGKP26CpkQw2uTew+qQQGuTLTr8UPN8OX+9SlKsdP8yiPAkVM/wuWYWf1UnSW8C/KD5/zWnH1OLIEDQk6rphQ8QWDCv3YmD6BQ2cEzNtkY1jgV6u9+3hRZN",
        "b5XU1A3tBlHtNFI8zfSR1tzW2VBztTqEK2o3iTml6SW+Xenkd1o1feUzbM7G5FSRaJAYTo1p6un/4ysptrPJQrXfOQ2lgHY0zGC6/4kAft8CAwEAAQ=="
    ].joined()

    // Extracted from the native nsrss ASR client in the installed Chatterfly build.
    static let asrRSAPublicKeyBase64 =
        "MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA042we0tp1Qf9oJ5HPTtDbevvl883q/e3FXXwnQbE7b4p6OqtVjQxprCusNKCiPPctzWUzOmLCnozWp/7j3sROdTDPK7ZtElf6fLL+l2bbdHijfSr0Z98yLwQOumOOPWtcxT34Ssrq5G3Sqaw8/RC9ZluoONqouzEl2ausPo21W+yctmIzQ8otMKOkTunNSg+f5bM7phhsYoNy4nkCiISuXjlVpEnvb9V0t4ih2sAAvqCmGim4PQODJqDDz68Iz0a32kMUIR1ydMqjoHokRdOk/VXgjE7OmJsVVe7Fn4ezdg7hYfnKVCPJxvzh0cgdbCMUUSXOP8foKnJEEoGIQcV+lYgKqNUSJJRrfzG33i58aRwJ29UOVHuhGJ/SqFXqNmTvYQR5/Y8kvMCoTdxQG6c5bWy9jTesrc/OliezEMS9GlepeiNdlHh3couDyn2zyYwE6aBpqp7k3uVQr/7PiAJ6ZDBQkzVX2PGyqFeAoPFE4xg6LLTYH4EydbpZXIDg4zzAgMBAAE="

    struct ASRConfigurationMaterial {
        let encryptedConfiguration: String
        let encryptedKey: String
        let encodedIV: String
    }

    static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ChatterflyCryptoError.randomFailure(status)
        }
        return data
    }

    static func rsaEncrypt(_ data: Data, publicKeyBase64: String = rsaPublicKeyBase64) throws -> Data {
        try rsaEncrypt(
            data,
            publicKeyBase64: publicKeyBase64,
            algorithm: .rsaEncryptionPKCS1,
            oaepHash: nil
        )
    }

    static func encryptASRConfiguration(_ data: Data) throws -> ASRConfigurationMaterial {
        let key = try randomData(count: 32)
        let iv = try randomData(count: 16)
        let encryptedConfiguration = try aes(
            data,
            key: key,
            iv: iv,
            operation: CCOperation(kCCEncrypt)
        ).base64EncodedString()
        let encryptedKey = try rsaEncrypt(
            key,
            publicKeyBase64: asrRSAPublicKeyBase64,
            algorithm: .rsaEncryptionRaw,
            oaepHash: asrOAEPHash()
        ).base64EncodedString()
        return ASRConfigurationMaterial(
            encryptedConfiguration: encryptedConfiguration,
            encryptedKey: encryptedKey,
            encodedIV: iv.base64EncodedString()
        )
    }

    private static func asrOAEPHash() -> ChatterflyOAEPHash {
        .sha256
    }

    private static func rsaEncrypt(
        _ data: Data,
        publicKeyBase64: String,
        algorithm: SecKeyAlgorithm,
        oaepHash: ChatterflyOAEPHash?
    ) throws -> Data {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw ChatterflyCryptoError.invalidPublicKey
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrIsPermanent: false
        ]
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else {
            throw ChatterflyCryptoError.invalidPublicKey
        }
        let input: Data
        if let oaepHash {
            input = try oaepEncode(data, keyByteCount: SecKeyGetBlockSize(publicKey), hash: oaepHash)
        } else {
            input = data
        }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            algorithm,
            input as CFData,
            &error
        ) else {
            throw ChatterflyCryptoError.rsaFailure
        }
        return encrypted as Data
    }

    private static func oaepEncode(_ message: Data, keyByteCount: Int, hash: ChatterflyOAEPHash) throws -> Data {
        try oaepEncode(message, keyByteCount: keyByteCount, hash: hash, seed: randomData(count: hash.digestLength))
    }

    private static func oaepEncode(
        _ message: Data,
        keyByteCount: Int,
        hash: ChatterflyOAEPHash,
        seed: Data
    ) throws -> Data {
        let digestLength = hash.digestLength
        guard message.count <= keyByteCount - (digestLength * 2) - 2 else {
            throw ChatterflyCryptoError.rsaFailure
        }
        guard seed.count == digestLength else {
            throw ChatterflyCryptoError.rsaFailure
        }

        let labelHash = hash.digest(Data())
        let paddingLength = keyByteCount - message.count - (digestLength * 2) - 2
        let dataBlock = labelHash
            + Data(repeating: 0, count: paddingLength)
            + Data([1])
            + message
        let dataBlockMask = mgf1(seed, count: keyByteCount - digestLength - 1, hash: hash)
        let maskedDataBlock = xor(dataBlock, dataBlockMask)
        let seedMask = mgf1(maskedDataBlock, count: digestLength, hash: hash)
        let maskedSeed = xor(seed, seedMask)
        return Data([0]) + maskedSeed + maskedDataBlock
    }

    private static func mgf1(_ seed: Data, count: Int, hash: ChatterflyOAEPHash) -> Data {
        var output = Data()
        var counter: UInt32 = 0
        while output.count < count {
            var counterData = Data()
            counterData.append(UInt8((counter >> 24) & 0xff))
            counterData.append(UInt8((counter >> 16) & 0xff))
            counterData.append(UInt8((counter >> 8) & 0xff))
            counterData.append(UInt8(counter & 0xff))
            output.append(hash.digest(seed + counterData))
            counter += 1
        }
        return output.prefix(count)
    }

    private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
        Data(zip(lhs, rhs).map { $0 ^ $1 })
    }

    static func aes(_ data: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        guard key.count == 32, iv.count == 16 else {
            throw ChatterflyCryptoError.invalidKeyLength
        }

        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ChatterflyCryptoError.aesFailure(status: status)
        }
        output.removeSubrange(outputLength ..< output.count)
        return output
    }

}

private enum ChatterflyOAEPHash {
    case ripemd160
    case sha1
    case sha256

    var digestLength: Int {
        switch self {
        case .ripemd160: return 20
        case .sha1: return Int(CC_SHA1_DIGEST_LENGTH)
        case .sha256: return Int(CC_SHA256_DIGEST_LENGTH)
        }
    }

    func digest(_ data: Data) -> Data {
        switch self {
        case .ripemd160:
            return ChatterflyRIPEMD160.digest(data)
        case .sha1:
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
            }
            return Data(digest)
        case .sha256:
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
            }
            return Data(digest)
        }
    }
}

enum ChatterflyRIPEMD160 {
    private static let leftRotation: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6
    ]
    private static let rightRotation: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11
    ]
    private static let leftIndex: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13
    ]
    private static let rightIndex: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11
    ]
    private static let leftConstant: [UInt32] = [0, 0x5a82_7999, 0x6ed9_eba1, 0x8f1b_bcdc, 0xa953_fd4e]
    private static let rightConstant: [UInt32] = [0x50a2_8be6, 0x5c4d_d124, 0x6d70_3ef3, 0x7a6d_76e9, 0]

    static func digest(_ input: Data) -> Data {
        var data = input
        let bitLength = UInt64(data.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xefcd_ab89
        var h2: UInt32 = 0x98ba_dcfe
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xc3d2_e1f0

        for offset in stride(from: 0, to: data.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = offset + index * 4
                words[index] = UInt32(data[base])
                    | (UInt32(data[base + 1]) << 8)
                    | (UInt32(data[base + 2]) << 16)
                    | (UInt32(data[base + 3]) << 24)
            }

            var leftA = h0, leftB = h1, leftC = h2, leftD = h3, leftE = h4
            var rightA = h0, rightB = h1, rightC = h2, rightD = h3, rightE = h4
            for index in 0..<80 {
                let leftRound = index / 16
                let rightRound = leftRound
                let leftValue = rotateLeft(
                    leftA &+ function(index: index, x: leftB, y: leftC, z: leftD)
                        &+ words[leftIndex[index]]
                        &+ leftConstant[leftRound],
                    by: leftRotation[index]
                ) &+ leftE
                leftA = leftE
                leftE = leftD
                leftD = rotateLeft(leftC, by: 10)
                leftC = leftB
                leftB = leftValue

                let rightValue = rotateLeft(
                    rightA &+ function(index: index, x: rightB, y: rightC, z: rightD, parallel: true)
                        &+ words[rightIndex[index]]
                        &+ rightConstant[rightRound],
                    by: rightRotation[index]
                ) &+ rightE
                rightA = rightE
                rightE = rightD
                rightD = rotateLeft(rightC, by: 10)
                rightC = rightB
                rightB = rightValue
            }

            let temporary = h1 &+ leftC &+ rightD
            h1 = h2 &+ leftD &+ rightE
            h2 = h3 &+ leftE &+ rightA
            h3 = h4 &+ leftA &+ rightB
            h4 = h0 &+ leftB &+ rightC
            h0 = temporary
        }

        var output = Data()
        for value in [h0, h1, h2, h3, h4] {
            output.append(UInt8(value & 0xff))
            output.append(UInt8((value >> 8) & 0xff))
            output.append(UInt8((value >> 16) & 0xff))
            output.append(UInt8((value >> 24) & 0xff))
        }
        return output
    }

    private static func function(index: Int, x: UInt32, y: UInt32, z: UInt32, parallel: Bool = false) -> UInt32 {
        if parallel {
            switch index / 16 {
            case 0: return x ^ (y | ~z)
            case 1: return (x & z) | (y & ~z)
            case 2: return (x | ~y) ^ z
            case 3: return (x & y) | (~x & z)
            default: return x ^ y ^ z
            }
        }
        switch index / 16 {
        case 0: return x ^ y ^ z
        case 1: return (x & y) | (~x & z)
        case 2: return (x | ~y) ^ z
        case 3: return (x & z) | (y & ~z)
        default: return x ^ (y | ~z)
        }
    }

    private static func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
