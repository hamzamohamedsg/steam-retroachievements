import Foundation
import RACore
import Security

/// The RetroAchievements username and Web API key, kept as one generic password item.
enum Keychain {
    static let service = "steam-retroachievements"

    static func load() -> RACredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any], let account = dict[kSecAttrAccount as String] as? String,
              let data = dict[kSecValueData as String] as? Data else { return nil }
        return RACredentials(username: account, apiKey: String(decoding: data, as: UTF8.self))
    }

    static func save(_ c: RACredentials) throws {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: c.username, kSecValueData as String: Data(c.apiKey.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
