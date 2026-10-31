import Foundation

public enum Titles {
    /// A display title from a ROM file name or shortcut name: no folder, extension, or `(...)`/`[...]` tags.
    public static func clean(_ fileOrName: String) -> String {
        var s = (fileOrName as NSString).lastPathComponent
        if let dot = s.lastIndex(of: ".") {
            let ext = s[s.index(after: dot)...]
            if (1...4).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                s = String(s[..<dot])
            }
        }
        s = s.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A matching key that ignores case, accents, punctuation, RA's `~Tag~` prefixes and a leading/trailing "The".
    public static func key(_ title: String) -> String {
        var s = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        s = s.replacingOccurrences(of: #"~[^~]*~|\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: ", the", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
