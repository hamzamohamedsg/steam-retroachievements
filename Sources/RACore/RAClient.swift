import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    /// Body and HTTP status.
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    // The timeouts are on the session as well: on Windows a request's own timeoutInterval isn't always honoured.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public init() {}
    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("steam-retroachievements/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum RAError: Error, Equatable { case badCredentials, http(Int), decoding, network }

public protocol RAProviding: Sendable {
    func gameList(consoleId: Int) async throws -> [RAGameListEntry]
    func gameProgress(gameId: Int) async throws -> RAGameProgress
}

public final class RAClient: RAProviding {
    let credentials: RACredentials
    let transport: HTTPTransport

    public init(credentials: RACredentials, transport: HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials; self.transport = transport
    }

    public func checkCredentials() async throws {
        _ = try await request("API_GetUserProfile.php", ["u": credentials.username])
    }

    public func gameList(consoleId: Int) async throws -> [RAGameListEntry] {
        try decode([RAGameListEntry].self, try await request("API_GetGameList.php", ["i": "\(consoleId)", "h": "1"]))
    }

    public func gameProgress(gameId: Int) async throws -> RAGameProgress {
        try decode(RAGameProgress.self, try await request("API_GetGameInfoAndUserProgress.php", ["g": "\(gameId)", "u": credentials.username]))
    }

    private func request(_ endpoint: String, _ params: [String: String]) async throws -> Data {
        let url = Self.url(base: "https://retroachievements.org/API/\(endpoint)", params: params.merging(["y": credentials.apiKey]) { $1 })
        // URLError descriptions include the request URL, and with it the API key: never let them escape.
        let data: Data, status: Int
        do { (data, status) = try await transport.get(url) } catch { throw RAError.network }
        if status == 401 { throw RAError.badCredentials }
        guard (200..<300).contains(status) else { throw RAError.http(status) }
        return data
    }

    /// Builds the query by hand: URLComponents leaves "&" and "+" unescaped inside values, which would corrupt an API key.
    static func url(base: String, params: [String: String]) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let query = params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
        return URL(string: "\(base)?\(query)")!
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try RADate.decoder.decode(type, from: data) } catch { throw RAError.decoding }
    }
}

/// Small JSON-on-disk cache; each entry remembers when it was saved.
public final class DiskCache: @unchecked Sendable {
    let directory: URL
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    struct Entry<T: Codable>: Codable { var savedAt: Date; var value: T }

    public func get<T: Codable>(_ key: String, as: T.Type) -> (value: T, savedAt: Date)? {
        guard let data = try? Data(contentsOf: file(key)),
              let e = try? RADate.decoder.decode(Entry<T>.self, from: data) else { return nil }
        return (e.value, e.savedAt)
    }

    public func put<T: Codable>(_ key: String, _ value: T, savedAt: Date = Date()) {
        guard let data = try? RADate.encoder.encode(Entry(savedAt: savedAt, value: value)) else { return }
        try? data.write(to: file(key), options: .atomic)
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }
}

/// Game lists come from the cache for 7 days; progress always comes fresh and is cached for fallback.
public final class CachedRA: RAProviding {
    static let gameListMaxAge: TimeInterval = 7 * 86_400
    let client: RAProviding
    let cache: DiskCache
    let now: @Sendable () -> Date

    public init(client: RAProviding, cache: DiskCache, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.cache = cache; self.now = now
    }

    public func gameList(consoleId: Int) async throws -> [RAGameListEntry] {
        let key = "gamelist-\(consoleId)"
        if let hit = cache.get(key, as: [RAGameListEntry].self), now().timeIntervalSince(hit.savedAt) < Self.gameListMaxAge {
            return hit.value
        }
        do {
            let list = try await client.gameList(consoleId: consoleId)
            cache.put(key, list, savedAt: now())
            return list
        } catch {
            // RA down: an old list still matches games better than nothing.
            if let stale = cache.get(key, as: [RAGameListEntry].self) { return stale.value }
            throw error
        }
    }

    public func gameProgress(gameId: Int) async throws -> RAGameProgress {
        let p = try await client.gameProgress(gameId: gameId)
        cache.put("progress-\(gameId)", p, savedAt: now())
        return p
    }

    public func cachedProgress(gameId: Int) -> (value: RAGameProgress, savedAt: Date)? {
        cache.get("progress-\(gameId)", as: RAGameProgress.self)
    }
}
