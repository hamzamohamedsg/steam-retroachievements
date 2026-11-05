import Foundation
import Testing
@testable import SteamBridge

/// Steam's SharedJSContext, when Steam on this machine has its DevTools port open. The tests below need it, so CI skips them.
private func steamTarget() async -> URL? {
    guard let targets = try? await SteamConnection.fetchTargets().get() else { return nil }
    return SteamConnection.sharedJSContext(in: targets)?.webSocketDebuggerUrl.flatMap(URL.init(string:))
}

private func evaluate(_ socket: DevToolsSocket, id: Int, _ expression: String) async throws {
    let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": "Runtime.evaluate", "params": ["expression": expression, "returnByValue": true]])
    try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, Error>) in
        socket.send(String(decoding: data, as: UTF8.self)) { error in
            if let error { sent.resume(throwing: error) } else { sent.resume() }
        }
    }
}

/// Reads replies to `ids` (their values, as text) until all are in, the connection ends, or `seconds` pass.
private func replies(_ socket: DevToolsSocket, ids: Set<Int>, seconds: Double = 30) async -> (values: [Int: String], ended: Bool) {
    await withTaskGroup(of: (values: [Int: String], ended: Bool)?.self) { group in
        group.addTask {
            var values: [Int: String] = [:]
            for await text in socket.messages {
                guard let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let id = msg["id"] as? Int, ids.contains(id) else { continue }
                values[id] = (((msg["result"] as? [String: Any])?["result"] as? [String: Any])?["value"]).map { "\($0)" } ?? "\(msg)"
                if values.count == ids.count { return (values, false) }
            }
            return Task.isCancelled ? nil : (values, true)
        }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? ([:], false)
    }
}

@Suite(.enabled("needs Steam running with its DevTools port open") { await steamTarget() != nil }, .serialized)
struct DevToolsSocketTests {
    @Test func evaluatesInSteam() async throws {
        let socket = try await DevToolsSocket.open(#require(await steamTarget()), maximumMessageSize: 1 << 20)
        defer { socket.close() }
        try await evaluate(socket, id: 1, "1 + 1")
        #expect(await replies(socket, ids: [1]).values == [1: "2"])
    }

    /// Far bigger than one read: it arrives in pieces that must join back up.
    @Test func bigMessageArrivesWhole() async throws {
        let socket = try await DevToolsSocket.open(#require(await steamTarget()), maximumMessageSize: 64 << 20)
        defer { socket.close() }
        try await evaluate(socket, id: 1, "'x'.repeat(5000000) + 'end'")
        let value = await replies(socket, ids: [1]).values[1]
        #expect(value?.count == 5_000_003)
        #expect(value?.hasSuffix("xend") == true)
    }

    /// Many commands in flight at once, sent from many tasks, while replies (some in pieces) come in.
    @Test func manyAtOnce() async throws {
        let socket = try await DevToolsSocket.open(#require(await steamTarget()), maximumMessageSize: 64 << 20)
        defer { socket.close() }
        let ids = Set(1...200)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await evaluate(socket, id: id, "'\(id) '.repeat(\(id * 100))") } }
            try await group.waitForAll()
        }
        let values = await replies(socket, ids: ids).values
        #expect(values.count == ids.count)
        for id in ids { #expect(values[id] == String(repeating: "\(id) ", count: id * 100)) }
    }

    @Test func closeEndsMessagesAndSends() async throws {
        let socket = try await DevToolsSocket.open(#require(await steamTarget()), maximumMessageSize: 1 << 20)
        try await evaluate(socket, id: 1, "1")
        #expect(await replies(socket, ids: [1]).values == [1: "1"])
        socket.close()
        #expect(await replies(socket, ids: [2], seconds: 15).ended)
        await #expect(throws: (any Error).self) { try await evaluate(socket, id: 3, "1") }
    }

    /// Like URLSession's maximumMessageSize: a message over the limit ends the connection.
    @Test func messageOverTheLimitEndsTheConnection() async throws {
        let socket = try await DevToolsSocket.open(#require(await steamTarget()), maximumMessageSize: 10_000)
        defer { socket.close() }
        try await evaluate(socket, id: 1, "'x'.repeat(200000)")
        let result = await replies(socket, ids: [1], seconds: 15)
        #expect(result.ended)
        #expect(result.values.isEmpty)
    }

    /// WinHTTP refuses the handshake; URLSession accepts the socket and then ends it.
    @Test func unknownTargetFails() async throws {
        var url = URLComponents(url: try #require(await steamTarget()), resolvingAgainstBaseURL: false)!
        url.path = "/devtools/page/no-such-target"
        guard let socket = try? await DevToolsSocket.open(url.url!, maximumMessageSize: 1 << 20) else { return }
        defer { socket.close() }
        #expect(await replies(socket, ids: [1], seconds: 15).ended)
    }
}
