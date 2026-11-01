import Foundation
import RACore
#if os(macOS)
import Security

/// The RetroAchievements username and Web API key, kept as one generic password item in the Keychain.
enum CredentialStore {
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
#else
#if os(Windows)
/// The RetroAchievements username and Web API key, encrypted with Windows' data protection (DPAPI) so only this Windows account can read them.
enum CredentialStore {
    struct Saved: Codable { var username, apiKey: String }
    static var file: URL { AppPaths.data.appendingPathComponent("credentials.dat") }
    /// Older versions kept the key as plain JSON; it's re-saved encrypted the first time it's read.
    static var legacyFile: URL { AppPaths.data.appendingPathComponent("credentials.json") }

    static func load() -> RACredentials? {
        if let data = try? Data(contentsOf: legacyFile), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            let c = RACredentials(username: s.username, apiKey: s.apiKey)
            if (try? save(c)) != nil { try? FileManager.default.removeItem(at: legacyFile) }
            return c
        }
        guard let blob = try? Data(contentsOf: file), let data = Dpapi.unprotect(blob),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return RACredentials(username: s.username, apiKey: s.apiKey)
    }

    static func save(_ c: RACredentials) throws {
        try FileManager.default.createDirectory(at: AppPaths.data, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Saved(username: c.username, apiKey: c.apiKey))
        guard let blob = Dpapi.protect(data) else { throw CocoaError(.fileWriteUnknown) }
        try blob.write(to: file, options: .atomic)
        try? FileManager.default.removeItem(at: legacyFile)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: legacyFile)
    }
}
#else
/// The RetroAchievements username and Web API key in a file only this user can read.
// shortcut: a 0600 file instead of libsecret, which Steam Deck's Game Mode has no unlocked keyring for;
// upgrade if a keyring becomes dependable there.
enum CredentialStore {
    struct Saved: Codable { var username, apiKey: String }
    static var file: URL { AppPaths.data.appendingPathComponent("credentials.json") }

    static func load() -> RACredentials? {
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return RACredentials(username: s.username, apiKey: s.apiKey)
    }

    static func save(_ c: RACredentials) throws {
        try FileManager.default.createDirectory(at: AppPaths.data, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Saved(username: c.username, apiKey: c.apiKey))
        // Create it private before the key goes in, so it is never readable by others.
        _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)  // an older file
        try data.write(to: file)  // not atomic: keeps the private file rather than replacing it
    }

    static func delete() { try? FileManager.default.removeItem(at: file) }
}
#endif
#endif
