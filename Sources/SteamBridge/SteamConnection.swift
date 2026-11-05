#if os(macOS)
import AppKit
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
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
    private var socket: DevToolsSocket?
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
    /// A port that answers wins: the process check can miss Steam (a Flatpak's own process names, say), and must not block connecting.
    public nonisolated static func decide(steamRunning: Bool, steamLaunched: Date?, markerCreated: Date?, portAnswered: Bool, now: Date) -> SteamState {
        if portAnswered { return .connecting }
        guard steamRunning else { return .steamNotRunning }
        if let launched = steamLaunched, let created = markerCreated, launched < created { return .needsRestart }
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
            let fetched = await Self.fetchTargets()
            let targets = try? fetched.get()
            if running, case .failure(let error) = fetched, "\(error)" != lastPortError {
                lastPortError = "\(error)"
                onError?("Steam's port check failed: \(error)")
            }
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
        return runningProgram("steam.exe")
        #else
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        let running = pids.contains { pid in
            pid.allSatisfy(\.isNumber) && (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "steam"
        }
        return (running, nil)
        #endif
    }

    #if os(Windows)
    /// Whether a program with this file name is running, and when it started. In-process: starting tasklist.exe every 3 s
    /// while Steam is closed cost more CPU than anything else the app did then.
    nonisolated static func runningProgram(_ exe: String) -> (running: Bool, launched: Date?) {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return (false, nil) }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var more = Process32FirstW(snapshot, &entry)
        while more {
            let name = withUnsafeBytes(of: entry.szExeFile) { String(decoding: $0.bindMemory(to: WCHAR.self).prefix { $0 != 0 }, as: UTF16.self) }
            if name.lowercased() == exe.lowercased() { return (true, processStart(entry.th32ProcessID)) }
            more = Process32NextW(snapshot, &entry)
        }
        return (false, nil)
    }

    nonisolated static func processStart(_ pid: DWORD) -> Date? {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(process) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &created, &exited, &kernel, &user) else { return nil }
        // FILETIME counts 100 ns steps since 1601.
        let ticks = UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
    }
    #endif

    /// A session of its own: on Windows a request's `timeoutInterval` isn't honoured for a refused connection (it took 60 s to fail),
    /// so the timeouts are set on the session too, which keeps the "is Steam's port open" check quick.
    private nonisolated static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        return URLSession(configuration: config)
    }()

    nonisolated static func fetchTargets() async -> Result<[CDPTarget], Error> {
        var req = URLRequest(url: listURL, timeoutInterval: 2)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await probeSession.data(for: req)
            return .success(try JSONDecoder().decode([CDPTarget].self, from: data))
        } catch {
            return .failure(error)
        }
    }

    /// The last reason the port check failed, so a steady "connection refused" is reported once, not every few seconds.
    private var lastPortError: String?

    private func connect(_ url: URL) async {
        do {
            let ws = try await DevToolsSocket.open(url, maximumMessageSize: 64 * 1024 * 1024)
            socket = ws
            receiveLoop(ws)
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
        socket?.close()
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
            socket.send(String(decoding: data, as: UTF8.self)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }.value
    }

    private func receiveLoop(_ ws: DevToolsSocket) {
        Task { [weak self] in
            for await text in ws.messages {
                guard let self, self.socket === ws else { return }
                self.handle(text)
            }
            // The connection ended: Steam quit or closed it.
            guard let self, self.socket === ws else { return }
            self.disconnect()
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
