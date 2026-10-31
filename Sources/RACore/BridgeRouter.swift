import Foundation

public protocol BridgeHandling: Sendable {
    /// `params` and the result are JSON.
    func handle(method: String, params: Data) async throws -> Data
}

/// Turns a `__sra_send` payload into the JS that delivers the reply: `window.__sra.receive({id, result|error})`.
public struct BridgeRouter: Sendable {
    let handler: BridgeHandling
    public init(handler: BridgeHandling) { self.handler = handler }

    public func respond(to payload: String) async -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let id = obj["id"] as? Int, let method = obj["method"] as? String,
              let params = try? JSONSerialization.data(withJSONObject: obj["params"] ?? [:]) else { return nil }
        do {
            let result = try await handler.handle(method: method, params: params)
            return "window.__sra.receive({\"id\":\(id),\"result\":\(String(decoding: result, as: UTF8.self))})"
        } catch {
            // Only our own error names reach the page; other errors' descriptions can carry URLs with the API key.
            let text = (error as? RAError).map { "\($0)" } ?? "internal error"
            let message = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
            return "window.__sra.receive({\"id\":\(id),\"error\":\(message)})"
        }
    }

    /// Links from the page may only open RetroAchievements itself (a trust boundary: the page is Steam's).
    public static func isAllowedExternalURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s) else { return false }
        return c.scheme == "https" && c.host == "retroachievements.org"
    }
}
