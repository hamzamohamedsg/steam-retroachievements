import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import CWinHTTP
import WinSDK
#endif

#if !os(Windows)
/// The WebSocket to one DevTools target: text messages out, and every text message in, in order.
final class DevToolsSocket: @unchecked Sendable {
    /// Each text message Steam sends; it finishes when the connection ends, from either side.
    let messages: AsyncStream<String>
    private let task: URLSessionWebSocketTask

    /// Returns at once: the handshake finishes in the background, and sends wait for it.
    static func open(_ url: URL, maximumMessageSize: Int) async throws -> DevToolsSocket {
        DevToolsSocket(url, maximumMessageSize: maximumMessageSize)
    }

    private init(_ url: URL, maximumMessageSize: Int) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        let (messages, continuation) = AsyncStream.makeStream(of: String.self)
        self.messages = messages
        task.resume()
        Self.receive(task, maximumMessageSize, continuation)
    }

    private static func receive(_ task: URLSessionWebSocketTask, _ limit: Int, _ continuation: AsyncStream<String>.Continuation) {
        task.receive { result in
            guard case .success(let message) = result else { return continuation.finish() }
            if case .string(let text) = message {
                // URLSession's maximumMessageSize isn't enforced on every macOS (28 delivers 200 KB past a 10 KB limit).
                guard text.utf8.count <= limit else {
                    task.cancel(with: .messageTooBig, reason: nil)
                    return continuation.finish()
                }
                continuation.yield(text)
            }
            receive(task, limit, continuation)
        }
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
#else
/// The WebSocket to one DevTools target, through WinHTTP: Foundation's URLSessionWebSocketTask keeps a CPU core busy
/// on Windows for as long as it's open, even with nothing to read. A thread of its own waits in WinHTTP's receive,
/// and sends go one at a time on a queue, as WinHTTP allows one of each at once.
final class DevToolsSocket: @unchecked Sendable {
    /// Each text message Steam sends; it finishes when the connection ends, from either side.
    let messages: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let connection: HINTERNET, socket: HINTERNET
    private let maximumMessageSize: Int
    private let sends = DispatchQueue(label: "steam-retroachievements.devtools-send")
    /// Whether `socket` is still a live handle. Held around every use of it outside the receive thread,
    /// so it's never closed under a send.
    private let lock = NSLock()
    private var open = true

    /// One session for every connection, as Microsoft advises: a session per connection leaves handles behind.
    /// Steam is on this machine, so the handshake gets a few seconds; these timeouts don't apply to the WebSocket's receive.
    nonisolated(unsafe) private static let session: HINTERNET? = {
        let session = WinHttpOpen(wide("Steam RetroAchievements"), DWORD(WINHTTP_ACCESS_TYPE_NO_PROXY), nil, nil, 0)
        if let session { WinHttpSetTimeouts(session, 2000, 2000, 5000, 5000) }
        return session
    }()

    /// Connects on a thread of its own, which then stays in the receive loop until the connection ends.
    static func open(_ url: URL, maximumMessageSize: Int) async throws -> DevToolsSocket {
        try await withCheckedThrowingContinuation { opened in
            do {
                try detachThread {
                    let socket: DevToolsSocket
                    do { socket = try DevToolsSocket(url, maximumMessageSize: maximumMessageSize) } catch { return opened.resume(throwing: error) }
                    opened.resume(returning: socket)
                    socket.receiveLoop()
                }
            } catch {
                opened.resume(throwing: error)
            }
        }
    }

    /// Foundation's Thread leaks each thread's handle on Windows, so this starts one with CreateThread and lets go of it.
    private static func detachThread(_ body: @escaping @Sendable () -> Void) throws {
        final class Body { let run: @Sendable () -> Void; init(_ run: @escaping @Sendable () -> Void) { self.run = run } }
        let context = Unmanaged.passRetained(Body(body)).toOpaque()
        guard let thread = CreateThread(nil, 0, { context in
            Unmanaged<Body>.fromOpaque(context!).takeRetainedValue().run()
            return 0
        }, context, 0, nil) else {
            let code = GetLastError()
            Unmanaged<Body>.fromOpaque(context).release()
            throw WinHTTPError(call: "CreateThread", code: code)
        }
        CloseHandle(thread)
    }

    private init(_ url: URL, maximumMessageSize: Int) throws {
        var handles: [HINTERNET] = []
        func fail(_ call: String, _ code: DWORD = GetLastError()) -> WinHTTPError {
            for handle in handles.reversed() { WinHttpCloseHandle(handle) }
            return WinHTTPError(call: call, code: code)
        }
        func kept(_ handle: HINTERNET?, _ call: String) throws -> HINTERNET {
            guard let handle else { throw fail(call) }
            handles.append(handle)
            return handle
        }

        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (parts?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let target = path + (parts?.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard let host = url.host, let port = INTERNET_PORT(exactly: url.port ?? 80) else { throw fail("URL \(url)", DWORD(ERROR_INVALID_PARAMETER)) }

        guard let session = Self.session else { throw fail("WinHttpOpen", 0) }
        let connection = try kept(WinHttpConnect(session, wide(host), port, 0), "WinHttpConnect")
        var request: HINTERNET, attempt = 0
        repeat {
            attempt += 1
            request = try kept(WinHttpOpenRequest(connection, wide("GET"), wide(target), nil, nil, nil,
                                                  url.scheme == "wss" ? DWORD(WINHTTP_FLAG_SECURE) : 0), "WinHttpOpenRequest")
            guard WinHttpSetOption(request, DWORD(WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET), nil, 0) else { throw fail("WinHttpSetOption") }
            if WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0) && WinHttpReceiveResponse(request, nil) { break }
            // After a refused handshake (a target that just went away), WinHTTP sends the next one on that connection,
            // which fails and is dropped: once more then gets a fresh connection.
            let code = GetLastError()
            guard attempt == 1, code == DWORD(ERROR_WINHTTP_INVALID_SERVER_RESPONSE) || code == DWORD(ERROR_WINHTTP_CONNECTION_ERROR) else {
                throw fail("WebSocket handshake", code)
            }
            WinHttpCloseHandle(handles.removeLast())
        } while true
        var status: DWORD = 0, size = DWORD(MemoryLayout<DWORD>.size)
        _ = WinHttpQueryHeaders(request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &status, &size, nil)
        guard status == 101 else { throw fail("WebSocket handshake (HTTP \(status))", 0) }
        guard let socket = WinHttpWebSocketCompleteUpgrade(request, 0) else { throw fail("WinHttpWebSocketCompleteUpgrade") }
        WinHttpCloseHandle(request)

        self.connection = connection
        self.socket = socket
        self.maximumMessageSize = maximumMessageSize
        (messages, continuation) = AsyncStream.makeStream(of: String.self)
    }

    /// On the socket's own thread: reads until the connection ends, then closes the handles and finishes `messages`.
    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), message: [UInt8] = []
        receiving: while true {
            var read: DWORD = 0
            var type = WINHTTP_WEB_SOCKET_BUFFER_TYPE(0)
            let error = buffer.withUnsafeMutableBytes { WinHttpWebSocketReceive(socket, $0.baseAddress, DWORD($0.count), &read, &type) }
            guard error == 0 else { break }
            switch type {
            case WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE:
                // A message bigger than the buffer comes in fragments, the last one typed as the message.
                message.append(contentsOf: buffer[..<Int(read)])
                guard message.count <= maximumMessageSize else { break receiving }
                if type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE {
                    continuation.yield(String(decoding: message, as: UTF8.self))
                    message = []
                }
            case WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE:
                break receiving
            default:
                continue  // binary: DevTools sends none
            }
        }
        lock.lock()
        if open { WinHttpCloseHandle(socket) }
        open = false
        lock.unlock()
        WinHttpCloseHandle(connection)
        continuation.finish()
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        sends.async { [self] in
            var bytes = Array(text.utf8)
            var error: Error? = SteamError.notConnected
            lock.lock()
            if open {
                let code = bytes.withUnsafeMutableBytes { WinHttpWebSocketSend(socket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, $0.baseAddress, DWORD($0.count)) }
                error = code == 0 ? nil : WinHTTPError(call: "WinHttpWebSocketSend", code: code)
            }
            lock.unlock()
            completion(error)
        }
    }

    /// Asks Steam to close; the receive loop ends with its answer. A Steam that's stuck never answers,
    /// so after a while the handle is closed under the receive, which then returns at once.
    func close() {
        sends.async { [self] in
            lock.lock()
            if open { _ = WinHttpWebSocketShutdown(socket, USHORT(WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS.rawValue), nil, 0) }
            lock.unlock()
        }
        sends.asyncAfter(deadline: .now() + 10) { [self] in
            lock.lock()
            if open { WinHttpCloseHandle(socket) }
            open = false
            lock.unlock()
        }
    }
}

private func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

struct WinHTTPError: Error, CustomStringConvertible {
    let call: String, code: DWORD
    var description: String { code == 0 ? "\(call) failed" : "\(call) failed (error \(code))" }
}
#endif
