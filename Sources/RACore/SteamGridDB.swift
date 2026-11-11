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
    private static let photo = "mimes=image/png,image/jpeg&types=static&nsfw=false&humor=false"
    private static let cutout = "mimes=image/png&types=static&nsfw=false&humor=false"
    /// Steam's asset types; nil is the icon, which Steam takes as a file instead.
    private static let kinds: [(assetType: Int?, path: String, query: String)] = [
        (0, "grids", "dimensions=600x900&" + photo),
        (3, "grids", "dimensions=920x430,460x215&" + photo),
        (1, "heroes", photo),
        (2, "logos", cutout),
        (nil, "icons", cutout),
    ]

    let key: String
    let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) { self.init(key: SteamGridDBKey.value, transport: transport) }
    init(key: String, transport: HTTPTransport) { self.key = key; self.transport = transport }

    private struct Reply<T: Decodable>: Decodable { var data: [T]? }
    private struct Game: Decodable { var id: Int }
    private struct Art: Decodable { var url: String }

    /// Empty when the build has no key or SteamGridDB doesn't know the game; any kind it lacks is left out.
    /// Throws what should stop further requests: a rate limit, a rejected key, no network.
    // shortcut: takes the first search hit, by title alone; upgrade with a "choose artwork" dialog if wrong matches get reported
    public func art(title: String) async throws -> (images: [ArtworkImage], icon: Data?) {
        var pathSafe = CharacterSet.urlPathAllowed
        pathSafe.remove(charactersIn: "/+")
        guard !key.isEmpty, let term = title.addingPercentEncoding(withAllowedCharacters: pathSafe) else { return ([], nil) }
        let games: [Game] = try await list("/search/autocomplete/\(term)")
        guard let game = games.first else { return ([], nil) }
        // All kinds at once: one after another took 10 round trips per game.
        let found = try await withThrowingTaskGroup(of: (Int, URL, Data)?.self) { group in
            for (i, kind) in Self.kinds.enumerated() {
                group.addTask {
                    let found: [Art] = try await list("/\(kind.path)/game/\(game.id)?\(kind.query)")
                    guard let url = found.lazy.compactMap({ Self.imageURL($0.url) }).first, let bytes = await download(url) else { return nil }
                    return (i, url, bytes)
                }
            }
            return try await group.reduce(into: [Int: (URL, Data)]()) { all, hit in if let hit { all[hit.0] = (hit.1, hit.2) } }
        }
        var images: [ArtworkImage] = [], icon: Data?
        for (i, kind) in Self.kinds.enumerated() {
            guard let (url, bytes) = found[i] else { continue }
            if let assetType = kind.assetType {
                images.append(ArtworkImage(assetType: assetType, ext: url.pathExtension.lowercased().replacingOccurrences(of: "jpeg", with: "jpg"), data: bytes.base64EncodedString()))
            } else {
                icon = bytes
            }
        }
        return (images, icon)
    }

    private func list<T: Decodable>(_ path: String) async throws -> [T] {
        guard let url = URL(string: Self.api + path) else { return [] }
        let data: Data, status: Int
        // URLError descriptions aren't let out, as in RAClient.
        do { (data, status) = try await transport.get(url, headers: ["Authorization": "Bearer \(key)"]) } catch { throw RAError.network }
        if status == 404 { return [] }
        guard (200..<300).contains(status) else { throw RAError.http(status) }
        return (try? JSONDecoder().decode(Reply<T>.self, from: data))?.data ?? []
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, status) = try? await transport.get(url), status == 200, data.count <= Self.maxImageBytes else { return nil }
        return data
    }

    /// Only SteamGridDB's own HTTPS images in a format Steam takes. A URL ending in "?" is an image removed by a takedown.
    static func imageURL(_ s: String) -> URL? {
        guard !s.hasSuffix("?"), let url = URL(string: s), url.scheme == "https", let host = url.host,
              host == "steamgriddb.com" || host.hasSuffix(".steamgriddb.com"),
              ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}
