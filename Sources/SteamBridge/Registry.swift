#if os(Windows)
import WinSDK

/// The registry reads and writes the app needs, done in-process: reg.exe is a console program, so it would flash a window.
public enum Registry {
    public enum Hive: Sendable { case currentUser, localMachine }

    static func root(_ hive: Hive) -> HKEY { hive == .currentUser ? HKEY_CURRENT_USER : HKEY_LOCAL_MACHINE }

    /// A text value (REG_EXPAND_SZ ones expanded), or nil when it's missing.
    public static func string(_ hive: Hive, _ key: String, _ name: String) -> String? {
        let key = wide(key), name = wide(name), flags = DWORD(RRF_RT_REG_SZ)
        var size: DWORD = 0
        guard RegGetValueW(root(hive), key, name, flags, nil, nil, &size) == ERROR_SUCCESS else { return nil }
        var buffer = [WCHAR](repeating: 0, count: Int(size) / 2 + 1)
        guard RegGetValueW(root(hive), key, name, flags, nil, &buffer, &size) == ERROR_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    @discardableResult
    public static func set(_ hive: Hive, _ key: String, _ name: String, _ value: String) -> Bool {
        let data = wide(value)
        return RegSetKeyValueW(root(hive), wide(key), wide(name), DWORD(REG_SZ), data, DWORD(data.count * 2)) == ERROR_SUCCESS
    }

    @discardableResult
    public static func delete(_ hive: Hive, _ key: String, _ name: String) -> Bool {
        RegDeleteKeyValueW(root(hive), wide(key), wide(name)) == ERROR_SUCCESS
    }

    /// The names of a key's subkeys.
    public static func subkeys(_ hive: Hive, _ key: String) -> [String] {
        enumerate(hive, key) { k, i, buf, len in RegEnumKeyExW(k, i, buf, len, nil, nil, nil, nil) }
    }

    /// The names of a key's values.
    public static func valueNames(_ hive: Hive, _ key: String) -> [String] {
        enumerate(hive, key) { k, i, buf, len in RegEnumValueW(k, i, buf, len, nil, nil, nil, nil) }
    }

    private static func enumerate(_ hive: Hive, _ key: String,
                                  _ item: (HKEY, DWORD, UnsafeMutablePointer<WCHAR>, UnsafeMutablePointer<DWORD>) -> LSTATUS) -> [String] {
        var k: HKEY?
        guard RegOpenKeyExW(root(hive), wide(key), 0, DWORD(KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS), &k) == ERROR_SUCCESS, let k else { return [] }
        defer { RegCloseKey(k) }
        var names: [String] = [], buffer = [WCHAR](repeating: 0, count: 32768), index: DWORD = 0
        while true {
            var length = DWORD(buffer.count)
            let status = buffer.withUnsafeMutableBufferPointer { item(k, index, $0.baseAddress!, &length) }
            if status == ERROR_NO_MORE_ITEMS { break }
            if status == ERROR_SUCCESS { names.append(String(decoding: buffer[..<Int(length)], as: UTF16.self)) }
            index += 1
        }
        return names
    }

    private static func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

    /// Steam's install folder as Steam records it (with forward slashes), or nil.
    public static var steamPath: String? {
        string(.currentUser, "Software\\Valve\\Steam", "SteamPath").flatMap { $0.isEmpty ? nil : $0 }
    }
}
#endif
