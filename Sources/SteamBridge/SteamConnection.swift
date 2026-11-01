#if os(macOS)
import AppKit
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CDPTarget: Decodable, Equatable, Sendable {
    public let id, title, type: String
    public let webSocketDebuggerUrl: String?
}

public enum SteamState: Equatable, Sendable { case steamNotRunning, needsRestart, connecting, connected }

public enum SteamError: Error { case notConnected, timedOut, evaluation(String) }

/// CDP results are plain JSON objects; they never leave the main actor.
struct JSONBox: @unchecked Sendable { let value: [String: Any] }

/// Keeps a CDP connection to Steam's SharedJSContext, injects the Steam-side script, and relays its binding calls.
@MainActor public final class SteamConnection {
    nonisolated static let bundleID = "com.valvesoftware.steam"
    nonisolated static let listURL = URL(string: "http://127.0.0.1:8080/json")!
    /// Seconds to wait for Steam to answer one DevTools command.
    nonisolated static let callTimeout = 20.0

    public private(set) var state: SteamState = .steamNotRunning {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((SteamState) -> Void)?
    public var onError: ((String) -> Void)?

    let marker: DebugMarker
    let script: () -> String
    let onBinding: @Sendable (String) async -> String?
    private var socket: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONBox, Error>] = [:]
    private var poller: Task<Void, Never>?
    /// When this app first saw Steam running: the launch time where the OS doesn't report one.
    private var steamSeen: Date?

    public init(marker: DebugMarker, script: @escaping () -> String, onBinding: @escaping @Sendable (String) async -> String?) {
        self.marker = marker; self.script = script; self.onBinding = onBinding
    }

    public func start() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Evaluates JS in SharedJSContext and returns its value (promises awaited).
    public func evaluate(_ js: String) async throws -> Any? {
        let res = try await call("Runtime.evaluate", ["expression": js, "awaitPromise": true, "returnByValue": true])
        if let ex = res["exceptionDetails"] as? [String: Any] {
            throw SteamError.evaluation(((ex["exception"] as? [String: Any])?["description"] as? String) ?? "\(ex)")
        }
        return (res["result"] as? [String: Any])?["value"]
    }

    #if os(macOS)
    public func restartSteam() async {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let url = app.bundleURL
        app.terminate()
        for _ in 0..<60 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(500)) }
        if let url { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    /// Brings Steam's window forward, e.g. after opening one of our dialogs in it.
    public func activateSteam() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.activate()
    }
    #endif

    public nonisolated static func sharedJSContext(in targets: [CDPTarget]) -> CDPTarget? {
        targets.first { $0.title == "SharedJSContext" && $0.webSocketDebuggerUrl != nil }
    }

    /// Steam reads the marker only at launch, so a Steam started before the marker (or one that never opens the port) needs a restart.
    public nonisolated static func decide(steamRunning: Bool, steamLaunched: Date?, markerCreated: Date?, portAnswered: Bool, now: Date) -> SteamState {
        guard steamRunning else { return .steamNotRunning }
        if let launched = steamLaunched, let created = markerCreated, launched < created { return .needsRestart }
        if portAnswered { return .connecting }
        if let launched = steamLaunched, now.timeIntervalSince(launched) >= 20 { return .needsRestart }
        return .connecting
    }

    // MARK: - Polling

    private var ticking = false

    private func tick() {
        guard !ticking, state != .connected else { return }
        ticking = true
        Task {
            defer { ticking = false }
            try? marker.ensure()
            let (running, launched) = Self.steamProcess()
            steamSeen = running ? steamSeen ?? Date() : nil
            let targets = await Self.fetchTargets()
            let next = Self.decide(steamRunning: running, steamLaunched: launched ?? steamSeen, markerCreated: marker.createdAt,
                                   portAnswered: targets != nil, now: Date())
            state = next
            if next == .connecting, let target = targets.flatMap(Self.sharedJSContext(in:)),
               let ws = target.webSocketDebuggerUrl.flatMap(URL.init(string:)) {
                await connect(ws)
            }
        }
    }

    /// Whether Steam is running, and when it started if the OS says.
    nonisolated static func steamProcess() -> (running: Bool, launched: Date?) {
        #if os(macOS)
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return (app != nil, app?.launchDate)
        #elseif os(Windows)
        let out = runProcess("C:\\Windows\\System32\\tasklist.exe", ["/FI", "IMAGENAME eq steam.exe", "/NH"]).output
        return (out.lowercased().contains("steam.exe"), nil)
        #else
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        let running = pids.contains { pid in
            pid.allSatisfy(\.isNumber) && (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "steam"
        }
        return (running, nil)
        #endif
    }

    /// A session of its own: on Windows a request's `timeoutInterval` isn't honoured for a refused connection (it took 60 s to fail),
    /// so the timeouts are set on the session too, which keeps the "is Steam's port open" check quick.
    private nonisolated static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetchTargets() async -> [CDPTarget]? {
        var req = URLRequest(url: listURL, timeoutInterval: 2)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await probeSession.data(for: req) else { return nil }
        return try? JSONDecoder().decode([CDPTarget].self, from: data)
    }

    private func connect(_ url: URL) async {
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws
        ws.resume()
        receiveLoop(ws)
        do {
            _ = try await call("Runtime.enable", [:])
            _ = try await call("Runtime.addBinding", ["name": "__sra_send"])
            _ = try await evaluate(script())
            state = .connected
        } catch {
            onError?("inject failed: \(error)")
            disconnect()
        }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for (_, c) in pending { c.resume(throwing: SteamError.notConnected) }
        pending = [:]
        state = .steamNotRunning
        tick()
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let socket else { throw SteamError.notConnected }
        let id = nextId
        nextId += 1
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONBox, Error>) in
            pending[id] = c
            // A reply that never comes would leave this call, and the polling that waits on it, stuck for good.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.callTimeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: SteamError.timedOut)
            }
            socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }.value
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === ws else { return }
                switch result {
                case .failure:
                    self.disconnect()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receiveLoop(ws)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let id = msg["id"] as? Int, let c = pending.removeValue(forKey: id) {
            if let err = msg["error"] as? [String: Any] {
                c.resume(throwing: SteamError.evaluation(err["message"] as? String ?? "CDP error"))
            } else {
                c.resume(returning: JSONBox(value: msg["result"] as? [String: Any] ?? [:]))
            }
        } else if msg["method"] as? String == "Runtime.bindingCalled",
                  let params = msg["params"] as? [String: Any], params["name"] as? String == "__sra_send",
                  let payload = params["payload"] as? String {
            let onBinding = onBinding
            Task {
                if let reply = await onBinding(payload) { _ = try? await self.evaluate(reply) }
            }
        } else if msg["method"] as? String == "Runtime.executionContextsCleared" {
            // SharedJSContext reloaded (e.g. Steam's web helper restarted): re-inject once its globals are back,
            // or reconnect from scratch so the next tick retries.
            Task {
                try? await Task.sleep(for: .seconds(2))
                do { _ = try await self.evaluate(self.script()) } catch {
                    self.onError?("re-inject failed: \(error)")
                    self.disconnect()
                }
            }
        }
    }
}
