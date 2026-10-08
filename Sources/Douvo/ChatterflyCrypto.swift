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
            oaepHash: .sha256
        ).base64EncodedString()
        return ASRConfigurationMaterial(
            encryptedConfiguration: encryptedConfiguration,
            encryptedKey: encryptedKey,
            encodedIV: iv.base64EncodedString()
        )
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
    case sha256

    var digestLength: Int {
        Int(CC_SHA256_DIGEST_LENGTH)
    }

    func digest(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: digestLength)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}
