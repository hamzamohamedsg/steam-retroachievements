import Foundation

extension SteamGridDBKey {
    // shortcut: masking only keeps the key out of plain text; anyone determined can recover it from the binary. Upgrade to a small proxy server if the key gets abused.
    static func unmask(_ bytes: [UInt8]) -> String { String(decoding: bytes.map { $0 ^ 0x5A }, as: UTF8.self) }
    static var value: String { unmask(masked) }
}

/// One image for `SteamClient.Apps.SetCustomArtworkForApp`: its asset type, file extension and base64 contents.
public struct ArtworkImage: Encodable, Equatable, Sendable {
    public var assetType: Int
    public var ext, data: String
}

/// Library artwork from SteamGridDB. The key stays here: it goes only in the API's Authorization header, never in a URL or to Steam's page.
public struct SteamGridDB: Sendable {
    static let api = "https://www.steamgriddb.com/api/v2"
    /// Images cross the bridge to Steam as base64.
    static let maxImageBytes = 20 * 1_048_576
    /// Below this Dice score a search hit is a different game: no art beats wrong art.
    static let minScore = 0.5
    /// Images tried per kind before giving up on it.
    static let triesPerKind = 3
    private static let photo = "mimes=image/png,image/jpeg&types=static&nsfw=false&humor=false"
    private static let cutout = "mimes=image/png&types=static&nsfw=false&humor=false"
    /// Steam's asset types; nil is the icon, which Steam takes as a file instead.
    private static let kinds: [(name: String, assetType: Int?, path: String, query: String)] = [
        ("grid", 0, "grids", "dimensions=600x900&" + photo),
        ("wide", 3, "grids", "dimensions=920x430,460x215&" + photo),
        ("hero", 1, "heroes", photo),
        ("logo", 2, "logos", cutout),
        ("icon", nil, "icons", cutout),
    ]

    let key: String
    let transport: HTTPTransport
    /// Seconds to wait before a retry; tests replace it.
    let sleep: @Sendable (Double) async -> Void

    public init(transport: HTTPTransport = URLSessionTransport()) { self.init(key: SteamGridDBKey.value, transport: transport) }
    init(key: String, transport: HTTPTransport, sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.key = key; self.transport = transport; self.sleep = sleep
    }

    private struct Reply<T: Decodable>: Decodable { var data: [T]? }
    struct Game: Decodable, Equatable { var id: Int; var name: String; var verified: Bool?; var release_date: Double? }
    private struct Art: Decodable {
        struct Author: Decodable { var name: String? }
        var url: String; var thumb: String?; var width, height: Int?; var style: String?; var author: Author?
    }

    /// A search hit for the "Choose artwork" dialog.
    public struct Match: Encodable, Equatable, Sendable { public var id: Int; public var name: String; public var year: Int?; public var verified: Bool }
    /// One image the dialog can offer.
    public struct Option: Encodable, Equatable, Sendable { public var url, thumb: String; public var width, height: Int?; public var style, author: String? }

    // MARK: matching

    /// ROM and RA names to something SteamGridDB knows: no tags, revision or disc suffixes, "Zelda, The" as "The Zelda".
    static func clean(_ title: String) -> String {
        var s = title
        for (pattern, template) in [
            (#"\.(zip|7z|nes|sfc|smc|gba|gbc|gb|n64|z64|v64|nds|3ds|iso|cue|chd|bin|gen|md|sms|gg|pce|a26|rom)$"#, ""),
            (#"\([^)]*\)|\[[^\]]*\]|~[^~]*~"#, " "),
            (#"\s+(?:Rev\s+[0-9A-Z]{1,2}|(?:Rev|Disc|Disk)\s*[0-9]+)\s*$"#, ""),
            (#"^(.+?),\s*(The|An|A)(?= - |:|\s*$)"#, "$2 $1"),
        ] { s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive]) }
        return s.split(separator: " ").joined(separator: " ")
    }

    /// Search terms in the order to try: the cleaned title, SteamGridDB's "Title: Subtitle" form, then the title without its subtitle.
    static func searchTerms(_ title: String) -> [String] {
        let cleaned = clean(title)
        let cut = [cleaned.range(of: ":"), cleaned.range(of: " - ")].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        let base = cut.map { String(cleaned[..<$0.lowerBound]).trimmingCharacters(in: .whitespaces) } ?? ""
        var seen = Set<String>()
        return [cleaned, cleaned.replacingOccurrences(of: " - ", with: ": "), base].filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let roman = ["ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"]
    private static func tokens(_ s: String) -> [String] {
        var t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if t.first == "the" { t.removeFirst() }
        return t.map { roman[$0] ?? $0 }
    }

    /// 1 for the same title; else the Dice overlap of the words, halved when both name different numbers (VII is not VIII), plus a little for verified games.
    static func score(_ query: String, _ name: String, verified: Bool = false) -> Double {
        let q = tokens(query), n = tokens(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if q == n { return 1 }
        let a = Set(q), b = Set(n)
        var s = 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
        let na = a.filter { $0.allSatisfy(\.isNumber) }, nb = b.filter { $0.allSatisfy(\.isNumber) }
        if !na.isEmpty, !nb.isEmpty, na != nb { s *= 0.5 }
        return min(0.99, s + (verified ? 0.05 : 0))
    }

    /// Best first; hits that score the same keep SteamGridDB's order.
    static func ranked(_ term: String, _ games: [Game]) -> [(game: Game, score: Double)] {
        games.enumerated().map { ($0.offset, $0.element, score(term, $0.element.name, verified: $0.element.verified == true)) }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    private func hits(_ term: String) async throws -> [Game] {
        var pathSafe = CharacterSet.urlPathAllowed
        pathSafe.remove(charactersIn: "/+")
        guard !key.isEmpty, let escaped = term.addingPercentEncoding(withAllowedCharacters: pathSafe) else { return [] }
        return try await list("/search/autocomplete/\(escaped)")
    }

    /// Every hit for what the user typed, best first.
    public func search(_ query: String) async throws -> [Match] {
        let term = Self.clean(query)
        return Self.ranked(term, try await hits(term)).map { g, _ in
            Match(id: g.id, name: g.name, year: g.release_date.map { Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: Date(timeIntervalSince1970: $0)).year! }, verified: g.verified == true)
        }
    }

    // MARK: images

    /// Empty when the build has no key or SteamGridDB has no convincing match; any kind it lacks is left out.
    /// Throws what should stop further requests: a rate limit, a rejected key, no network.
    public func art(title: String) async throws -> (images: [ArtworkImage], icon: Data?) {
        for term in Self.searchTerms(title) {
            if let best = Self.ranked(term, try await hits(term)).first, best.score >= Self.minScore { return try await art(gameId: best.game.id) }
        }
        return ([], nil)
    }

    public func art(gameId: Int) async throws -> (images: [ArtworkImage], icon: Data?) {
        // All kinds at once: one after another took 10 round trips per game.
        let found = try await withThrowingTaskGroup(of: (Int, URL, Data)?.self) { group in
            for (i, kind) in Self.kinds.enumerated() {
                group.addTask {
                    let found: [Art] = try await list("/\(kind.path)/game/\(gameId)?\(kind.query)")
                    for url in found.lazy.compactMap({ Self.imageURL($0.url) }).prefix(Self.triesPerKind) {
                        if let bytes = await download(url) { return (i, url, bytes) }
                    }
                    return nil
                }
            }
            return try await group.reduce(into: [Int: (URL, Data)]()) { all, hit in if let hit { all[hit.0] = (hit.1, hit.2) } }
        }
        var images: [ArtworkImage] = [], icon: Data?
        for (i, kind) in Self.kinds.enumerated() {
            guard let (url, bytes) = found[i] else { continue }
            if let assetType = kind.assetType { images.append(Self.image(assetType, url, bytes)) } else { icon = bytes }
        }
        return (images, icon)
    }

    /// The images SteamGridDB has for a game, best rated first.
    public func options(gameId: Int, kind: String) async throws -> [Option] {
        guard !key.isEmpty, let k = Self.kinds.first(where: { $0.name == kind }) else { return [] }
        let found: [Art] = try await list("/\(k.path)/game/\(gameId)?\(k.query)")
        return found.compactMap { a in
            guard let url = Self.imageURL(a.url) else { return nil }
            return Option(url: url.absoluteString, thumb: a.thumb.flatMap(Self.secureURL)?.absoluteString ?? url.absoluteString,
                          width: a.width, height: a.height, style: a.style, author: a.author?.name)
        }.prefix(40).map { $0 }
    }

    /// Downloads one image the user picked. Only SteamGridDB's own images: the page can't make the app fetch anything else.
    public func fetch(kind: String, url: String) async throws -> (image: ArtworkImage?, icon: Data?) {
        guard let k = Self.kinds.first(where: { $0.name == kind }), let url = Self.imageURL(url) else { throw RAError.decoding }
        guard let bytes = await download(url) else { throw RAError.network }
        return (k.assetType.map { Self.image($0, url, bytes) }, k.assetType == nil ? bytes : nil)
    }

    private static func image(_ assetType: Int, _ url: URL, _ bytes: Data) -> ArtworkImage {
        ArtworkImage(assetType: assetType, ext: url.pathExtension.lowercased().replacingOccurrences(of: "jpeg", with: "jpg"), data: bytes.base64EncodedString())
    }

    /// Retries a rate limit or server error twice, waiting what Retry-After says (at most 10 s).
    private func list<T: Decodable>(_ path: String) async throws -> [T] {
        guard let url = URL(string: Self.api + path) else { return [] }
        var attempt = 0
        while true {
            let r: (data: Data, status: Int, retryAfter: Double?)
            // URLError descriptions aren't let out, as in RAClient.
            do { r = try await transport.response(url, headers: ["Authorization": "Bearer \(key)"]) } catch { throw RAError.network }
            if (r.status == 429 || r.status >= 500) && attempt < 2 {
                await sleep(min(r.retryAfter ?? Double(1 + 2 * attempt), 10))
                attempt += 1
                continue
            }
            if r.status == 404 { return [] }
            guard (200..<300).contains(r.status) else { throw RAError.http(r.status) }
            return (try? JSONDecoder().decode(Reply<T>.self, from: r.data))?.data ?? []
        }
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, status) = try? await transport.get(url), status == 200, data.count <= Self.maxImageBytes else { return nil }
        return data
    }

    static func secureURL(_ s: String) -> URL? {
        guard let url = URL(string: s), url.scheme == "https", let host = url.host, host == "steamgriddb.com" || host.hasSuffix(".steamgriddb.com") else { return nil }
        return url
    }

    /// Only SteamGridDB's own HTTPS images in a format Steam takes. A URL ending in "?" is an image removed by a takedown.
    static func imageURL(_ s: String) -> URL? {
        guard !s.hasSuffix("?"), let url = secureURL(s), ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}
