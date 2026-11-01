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

    /// "Bonus" for RA's `Sonic the Hedgehog [Subset - Bonus]`; nil for a base game.
    public static func subsetName(_ title: String) -> String? {
        guard let r = title.range(of: #"\[Subset - ([^\]]+)\]"#, options: .regularExpression) else { return nil }
        return String(title[r].dropFirst("[Subset - ".count).dropLast())
    }

    /// A matching key that ignores case, accents, punctuation, RA's `~Tag~` prefixes and a leading/trailing "The".
    public static func key(_ title: String) -> String {
        var s = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        s = s.replacingOccurrences(of: #"~[^~]*~|\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&", with: " and ")
        // "Legend of Zelda, The" and "Legend of Zelda, The: Ocarina", but not the ", the" inside "Breathe, theory".
        s = s.replacingOccurrences(of: #",\s*the(?![a-z0-9])"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
