import CommonCrypto
import Foundation

enum ChatterflyNativeIdentityStore {
    private static let userIDKey = "gYBLoginInfoUserId"
    private static let accessTokenKey = "kCurrentUserToken"
    private static let accsRelativePath = "Library/Application Support/Chatterfly/InputMethod/ChatterflyPY.users/accs.dat"
    private static let aesKey = Data("vc8v7vghw7v278vn2v8239vh29vh890m".utf8)
    private static let aesIV = Data("aqkeezgxijvlm2op".utf8)

    static func currentUserID(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        currentUserID(
            at: homeDirectory.appendingPathComponent(accsRelativePath)
        )
    }

    static func currentUserID(at url: URL) -> String? {
        value(forKey: userIDKey, at: url)
    }

    static func currentAccessToken(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        currentAccessToken(
            at: homeDirectory.appendingPathComponent(accsRelativePath)
        )
    }

    static func currentAccessToken(at url: URL) -> String? {
        value(forKey: accessTokenKey, at: url)
    }

    private static func value(forKey key: String, at url: URL) -> String? {
        guard let encoded = try? Data(contentsOf: url),
              let encrypted = Data(base64Encoded: encoded),
              let decrypted = try? ChatterflyCrypto.aes(
                  encrypted,
                  key: aesKey,
                  iv: aesIV,
                  operation: CCOperation(kCCDecrypt)
              ),
              let archived = unarchive(decrypted),
              let dictionary = archived as? NSDictionary,
              let value = dictionary[key] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func unarchive(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }
}

enum ChatterflySCookie {
    static func make(inputMethodVersion: String, userID: String?, qimei36: String) -> String {
        var components = ["c=\(inputMethodVersion)", "e=mac"]
        if let userID, !userID.isEmpty {
            components.append("w=\(userID)")
        }
        components.append("qi=\(qimei36)")
        return components.joined(separator: "&")
    }

    static func make2(
        inputMethodVersion: String,
        userID: String?,
        sgid: String,
        qimei36: String
    ) -> String {
        "a=2&b=SogouInput&c=\(inputMethodVersion)&e=mac&w=\(userID ?? "")&sgid=\(sgid)&qi=\(qimei36)"
    }
}
