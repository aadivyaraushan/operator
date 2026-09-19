import Foundation
import Network
import OSLog

enum LocalOAuthCallbackError: Error, Equatable, Sendable {
    case alreadyStarted, notRunning, bindFailed, invalidRequest, timedOut
}

typealias NotionLoopbackCallbackError = LocalOAuthCallbackError

actor LocalOAuthCallbackServer {
    private let path: String
    private let logTag: String
    private let timeoutSeconds: Double
    private let requestTimeoutSeconds: Double
    private let logger: Logger
    private var listener: NWListener?
    private var port: UInt16?
    private var result: Result<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var receiveStarted = false

    init(
        path: String = "/notion/callback",
        logTag: String = "notion-loopback",
        timeoutSeconds: Double = 300,
        requestTimeoutSeconds: Double = 5
    ) {
        self.path = path
        self.logTag = logTag
        self.timeoutSeconds = min(max(timeoutSeconds, 0.01), 300)
        self.requestTimeoutSeconds = min(max(requestTimeoutSeconds, 0.01), 10)
        self.logger = Logger(subsystem: "app.operator.ios", category: logTag)
    }

    func start(port requestedPort: UInt16?) async throws -> URL {
        guard listener == nil, result == nil else { throw LocalOAuthCallbackError.alreadyStarted }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: requestedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw LocalOAuthCallbackError.bindFailed }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let queue = DispatchQueue(label: "app.operator.ios.notion-loopback")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    Task { await self?.recordReadyPort(listener.port?.rawValue) }
                    continuation.resume()
                case .failed:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: LocalOAuthCallbackError.bindFailed)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let boundPort = listener.port?.rawValue else {
            listener.cancel()
            self.listener = nil
            throw LocalOAuthCallbackError.bindFailed
        }
        self.port = boundPort
        logger.info("[\(self.logTag, privacy: .public)] listening loopback=true port_selected=true")
        return URL(string: "http://127.0.0.1:\(boundPort)\(path)")!
    }

    func receive(expectedState: String) async throws -> URL {
        guard !receiveStarted else { throw LocalOAuthCallbackError.notRunning }
        receiveStarted = true
        if let result { return try result.get() }
        guard listener != nil else { throw LocalOAuthCallbackError.notRunning }
        return try await withTaskCancellationHandler {
            let timeout = Task { [timeoutSeconds] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self.stop(with: .failure(LocalOAuthCallbackError.timedOut))
            }
            defer { timeout.cancel() }
            defer { stop(with: nil) }
            return try await awaitResult(expectedState: expectedState)
        } onCancel: {
            Task { await self.stop(with: .failure(CancellationError())) }
        }
    }

    func cancel() { stop(with: .failure(CancellationError())) }

    private func recordReadyPort(_ value: UInt16?) { port = value }

    private func awaitResult(expectedState: String) async throws -> URL {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            expectedStateValue = expectedState
        }
    }

    private var expectedStateValue: String?

    private func accept(_ connection: NWConnection) {
        guard waiter != nil, let port else { connection.cancel(); return }
        connection.start(queue: DispatchQueue(label: "app.operator.ios.notion-loopback.request"))
        let readTimeout = Task { [requestTimeoutSeconds] in
            try? await Task.sleep(for: .seconds(requestTimeoutSeconds))
            guard !Task.isCancelled else { return }
            connection.cancel()
            self.finish(.failure(LocalOAuthCallbackError.invalidRequest))
        }
        read(connection, accumulated: Data(), port: port, readTimeout: readTimeout)
    }

    private func read(
        _ connection: NWConnection,
        accumulated: Data,
        port: UInt16,
        readTimeout: Task<Void, Never>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192 - accumulated.count) {
            [weak self] data, _, complete, error in
            var combined = accumulated
            if let data { combined.append(data) }
            if combined.range(of: Data("\r\n\r\n".utf8)) != nil {
                readTimeout.cancel()
                Task { await self?.process(combined, connection: connection, port: port) }
            } else if complete || error != nil || combined.count >= 8_192 {
                readTimeout.cancel()
                connection.cancel()
                Task { await self?.finish(.failure(LocalOAuthCallbackError.invalidRequest)) }
            } else {
                Task { await self?.read(connection, accumulated: combined, port: port, readTimeout: readTimeout) }
            }
        }
    }

    private func process(_ data: Data, connection: NWConnection, port: UInt16) {
        let parsed = Self.parse(data, port: port, path: path, expectedState: expectedStateValue ?? "")
        let status = parsed == nil ? "400 Bad Request" : "200 OK"
        let body = parsed == nil ? "Invalid OAuth callback." : "Authorization received. Return to Operator."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if let parsed {
            logger.info("[\(self.logTag, privacy: .public)] callback accepted")
            finish(.success(parsed))
        } else {
            logger.error("[\(self.logTag, privacy: .public)] callback rejected invalid_shape=true")
            finish(.failure(LocalOAuthCallbackError.invalidRequest))
        }
    }

    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value
        let saved = waiter
        waiter = nil
        saved?.resume(with: value)
    }

    private func stop(with value: Result<URL, Error>?) {
        if let value { finish(value) }
        listener?.cancel()
        listener = nil
        port = nil
        if result == nil { finish(.failure(LocalOAuthCallbackError.timedOut)) }
    }

    private static func parse(_ data: Data, port: UInt16, path: String, expectedState: String) -> URL? {
        guard data.count <= 8_192, let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let pieces = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "GET", pieces[2] == "HTTP/1.1",
              lines.dropFirst().filter({ $0.lowercased().hasPrefix("host:") }).count == 1,
              lines.dropFirst().first(where: { $0.lowercased().hasPrefix("host:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)",
              var components = URLComponents(string: "http://127.0.0.1:\(port)\(pieces[1])"),
              components.path == path,
              let items = components.queryItems else { return nil }
        var query: [String: String] = [:]
        let protectedFields: Set<String> = ["code", "state", "error", "error_description", "error_uri"]
        for item in items where protectedFields.contains(item.name) {
            guard query[item.name] == nil, let value = item.value, !value.isEmpty else { return nil }
            query[item.name] = value
        }
        guard query["state"] == expectedState,
              (query["code"] != nil) != (query["error"] != nil) else { return nil }
        components.fragment = nil
        return components.url
    }

    static func receiveFirst(
        server: LocalOAuthCallbackServer,
        expectedState: String,
        browser: @escaping @Sendable () async throws -> URL,
        cancelBrowser: @escaping @Sendable () async -> Void
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await server.receive(expectedState: expectedState) }
                group.addTask { try await browser() }
                do {
                    guard let first = try await group.next() else { throw CancellationError() }
                    await cancelBrowser()
                    await server.cancel()
                    group.cancelAll()
                    return first
                } catch {
                    await cancelBrowser()
                    await server.cancel()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            Task {
                await cancelBrowser()
                await server.cancel()
            }
        }
    }
}

typealias NotionLoopbackCallbackServer = LocalOAuthCallbackServer
