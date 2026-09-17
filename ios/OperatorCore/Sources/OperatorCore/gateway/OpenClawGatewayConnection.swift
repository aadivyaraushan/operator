import Foundation
import OSLog

public protocol GatewayTransport: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public struct GatewayConnectionMetadata: Equatable, Sendable {
    public let appVersion: String
    public let platform: String
    public let instanceID: String

    public init(appVersion: String, platform: String, instanceID: String) {
        self.appVersion = appVersion
        self.platform = platform
        self.instanceID = instanceID
    }
}

public enum OpenClawGatewayError: Error, Equatable, Sendable {
    case invalidChallenge
    case invalidFrame
    case notConnected
    case recoveryPending
    case rejected(code: String, message: String)
    case transport(String)
}

public enum GatewayInbound: Equatable, Sendable {
    case conversation([GatewayConversationEvent])
    case approval(GatewaySessionApprovalEvent)
    case question(GatewayQuestionEvent)
    case response(
        id: String,
        ok: Bool,
        runID: String?,
        status: String?,
        error: GatewayResponseFrame.Failure?)
    case ignored(event: String)
}

public actor OpenClawGatewayConnection {
    public static let defaultSessionKey = "agent:main:main"
    public static let defaultAgentID = String(
        OpenClawGatewayConnection.defaultSessionKey
            .split(separator: ":", omittingEmptySubsequences: false)
            .dropFirst()
            .first ?? "")
    public private(set) var isConnected = false
    public private(set) var currentGatewayBootID: String?

    private let transport: any GatewayTransport
    private let token: String
    private let identity: GatewayDeviceIdentity
    private let metadata: GatewayConnectionMetadata
    private let sessionKey: String
    private let requestID: @Sendable () -> String
    private let pairingRetryDelay: @Sendable () async -> Void
    private let logger = Logger(subsystem: "app.operator.ios", category: "gateway")
    private let typedRequestQueue = TypedRequestQueue()
    private var reducer: GatewayEventReducer
    private var bufferedInbound: [GatewayInbound] = []

    var authenticatedDeviceID: String { self.identity.deviceID }
    var authenticatedPublicKey: String {
        self.identity.publicKey.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init(
        transport: any GatewayTransport,
        token: String,
        identity: GatewayDeviceIdentity,
        metadata: GatewayConnectionMetadata,
        sessionKey: String = OpenClawGatewayConnection.defaultSessionKey,
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        pairingRetryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(250))
        })
    {
        self.transport = transport
        self.token = token
        self.identity = identity
        self.metadata = metadata
        self.sessionKey = sessionKey
        self.requestID = requestID
        self.pairingRetryDelay = pairingRetryDelay
        self.reducer = GatewayEventReducer(sessionKey: sessionKey)
    }

    public func connect() async throws {
        guard !self.isConnected else { return }
        var pairingRetriesRemaining = 40
        while true {
            self.logger.info("[gateway] opening local websocket")
            do {
                try await self.connectOnce()
                return
            } catch {
                self.isConnected = false
                self.currentGatewayBootID = nil
                await self.transport.close()
                let gatewayError = (error as? OpenClawGatewayError)
                    ?? OpenClawGatewayError.transport(String(describing: error))
                if case let .rejected(code, _) = gatewayError,
                   code == "NOT_PAIRED",
                   pairingRetriesRemaining > 0
                {
                    pairingRetriesRemaining -= 1
                    self.logger.info(
                        "[gateway] exact-device pairing pending retriesRemaining=\(pairingRetriesRemaining)")
                    await self.pairingRetryDelay()
                    continue
                }
                self.logger.error(
                    "[gateway] connect failed error=\(String(describing: gatewayError), privacy: .public)")
                throw gatewayError
            }
        }
    }

    private func connectOnce() async throws {
        try await self.transport.open()
        let challengeData = try await self.transport.receive()
        let challengeFrame = try JSONDecoder().decode(
            GatewayEventFrame<GatewayConnectChallenge>.self,
            from: challengeData)
        let challenge = challengeFrame.payload
        guard challengeFrame.type == "event",
              challengeFrame.event == "connect.challenge",
              !challenge.nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              challenge.issuedAtMilliseconds >= 0
        else {
            throw OpenClawGatewayError.invalidChallenge
        }

        let connectID = self.requestID()
        let request = try GatewayRequestFactory.connect(
            requestID: connectID,
            token: self.token,
            identity: self.identity,
            challenge: challenge,
            appVersion: self.metadata.appVersion,
            platform: self.metadata.platform,
            instanceID: self.metadata.instanceID)
        try await self.transport.send(try JSONEncoder().encode(request))

        while true {
            let responseData = try await self.transport.receive()
            let header = try JSONDecoder().decode(FrameHeader.self, from: responseData)
            guard header.type == "res", header.id == connectID else {
                continue
            }
            let response = try JSONDecoder().decode(
                GatewayRPCResponseFrame<GatewayHelloPayload>.self, from: responseData)
            guard response.ok else {
                let failure = response.error
                throw OpenClawGatewayError.rejected(
                    code: failure?.code ?? "CONNECT_REJECTED",
                    message: failure?.message ?? "Gateway rejected the connection")
            }
            let bootID = response.payload?.server?.bootId?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.currentGatewayBootID = bootID?.isEmpty == false ? bootID : nil
            self.isConnected = true
            self.logger.info("[gateway] connected protocol=4 bootIdentityAvailable=\(self.currentGatewayBootID != nil)")
            return
        }
    }

    @discardableResult
    public func sendMessage(_ message: String, idempotencyKey: String) async throws -> String {
        guard self.isConnected else { throw OpenClawGatewayError.notConnected }
        let id = self.requestID()
        let request = GatewayRequestFactory.chatSend(
            requestID: id,
            sessionKey: self.sessionKey,
            message: message,
            idempotencyKey: idempotencyKey)
        try await self.transport.send(try JSONEncoder().encode(request))
        self.logger.info("[gateway] sent chat request id=\(id, privacy: .public)")
        return id
    }

    @discardableResult
    public func abort(runID: String?) async throws -> String {
        guard self.isConnected else { throw OpenClawGatewayError.notConnected }
        let id = self.requestID()
        let request = GatewayRequestFactory.chatAbort(
            requestID: id,
            sessionKey: self.sessionKey,
            runID: runID)
        try await self.transport.send(try JSONEncoder().encode(request))
        return id
    }

    public func subscribeToSessionApprovals() async throws -> GatewayApprovalReplay {
        let result: GatewaySessionsMessagesSubscribeResult = try await self.request(
            method: "sessions.messages.subscribe",
            params: GatewaySessionsMessagesSubscribeParams(key: self.sessionKey, includeApprovals: true))
        guard result.subscribed,
              result.key == self.sessionKey,
              let replay = result.approvalReplay,
              replay.sessionKey == self.sessionKey
        else {
            self.logger.error("[approval] subscription response missing the exact session replay")
            throw OpenClawGatewayError.invalidFrame
        }
        self.logger.info("[approval] subscribed pendingCount=\(replay.approvals.count)")
        return replay
    }

    public func recoverReply(runID: String) async throws -> String? {
        let result: GatewayChatHistoryResult = try await self.request(
            method: "chat.history",
            params: GatewayChatHistoryParams(sessionKey: self.sessionKey))
        let reply = result.exactAssistantReply(runID: runID)
        if reply == nil, let recovery = result.operatorRecovery,
           recovery.sourceRunId == runID, !recovery.runId.isEmpty {
            self.logger.info("[gateway] exact request has native recovery pending")
            throw OpenClawGatewayError.recoveryPending
        }
        self.logger.info(
            "[gateway] exact terminal reply recovery runID=\(runID, privacy: .public) found=\(reply != nil)")
        return reply
    }

    public func resolveApproval(
        id: String,
        kind: GatewayApprovalKind,
        decision: GatewayApprovalDecision) async throws -> GatewayApprovalResolveResult
    {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawGatewayError.invalidFrame
        }
        let result: GatewayApprovalResolveResult = try await self.request(
            method: "approval.resolve",
            params: GatewayApprovalResolveParams(id: id, kind: kind, decision: decision))
        guard result.approval.id == id,
              result.approval.presentation.kind == kind,
              result.approval.status != .pending
        else {
            self.logger.error("[approval] rejected canonical resolution id=\(id, privacy: .public)")
            throw OpenClawGatewayError.invalidFrame
        }
        self.logger.info("[approval] canonical resolution received id=\(id, privacy: .public)")
        return result
    }

    /// Every question the gateway still holds for this session. Called on
    /// each foreground subscription, so a question asked while the socket
    /// was down is not missed: the model is still waiting on it.
    public func listQuestions() async throws -> [GatewayQuestionRecord] {
        let result: GatewayQuestionListResult = try await self.request(
            method: "question.list", params: GatewayQuestionListParams())
        let mine = result.questions.filter { $0.sessionKey == nil || $0.sessionKey == self.sessionKey }
        self.logger.info("[question] listed pendingCount=\(mine.filter { $0.status == .pending }.count)")
        return mine
    }

    /// Answers a question and checks the gateway recorded exactly that.
    public func answerQuestion(id: String, answers: GatewayQuestionAnswers) async throws -> GatewayQuestionResolveResult {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !answers.answers.isEmpty else {
            throw OpenClawGatewayError.invalidFrame
        }
        let result: GatewayQuestionResolveResult = try await self.request(
            method: "question.resolve",
            params: GatewayQuestionAnswerParams(id: id, answers: answers, resolvedBy: "operator-ios"))
        guard result.status == .answered, result.answers == answers else {
            self.logger.error("[question] gateway recorded a different answer id=\(id, privacy: .public) status=\(result.status.rawValue, privacy: .public)")
            throw OpenClawGatewayError.invalidFrame
        }
        self.logger.info("[question] answered id=\(id, privacy: .public)")
        return result
    }

    /// Cancels a question: the model gets "no answer" and carries on.
    public func cancelQuestion(id: String) async throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenClawGatewayError.invalidFrame
        }
        let result: GatewayQuestionResolveResult = try await self.request(
            method: "question.resolve",
            params: GatewayQuestionCancelParams(id: id, resolvedBy: "operator-ios"))
        guard result.status == .cancelled else {
            self.logger.error("[question] cancel not recorded id=\(id, privacy: .public) status=\(result.status.rawValue, privacy: .public)")
            throw OpenClawGatewayError.invalidFrame
        }
        self.logger.info("[question] cancelled id=\(id, privacy: .public)")
    }

    public func receive() async throws -> GatewayInbound {
        guard self.isConnected else { throw OpenClawGatewayError.notConnected }
        if !self.bufferedInbound.isEmpty {
            return self.bufferedInbound.removeFirst()
        }
        do {
            let data = try await self.transport.receive()
            return try self.decodeInbound(data)
        } catch {
            if let gatewayError = error as? OpenClawGatewayError {
                throw gatewayError
            }
            throw OpenClawGatewayError.transport(String(describing: error))
        }
    }

    private func decodeInbound(_ data: Data) throws -> GatewayInbound {
        let header = try JSONDecoder().decode(FrameHeader.self, from: data)
        switch header.type {
        case "res":
            let response = try JSONDecoder().decode(GatewayResponseFrame.self, from: data)
            return .response(
                id: response.id,
                ok: response.ok,
                runID: response.payload?.runID,
                status: response.payload?.status,
                error: response.error)
        case "event" where header.event == "chat":
            let frame = try JSONDecoder().decode(GatewayEventFrame<GatewayChatEvent>.self, from: data)
            return .conversation(self.reducer.apply(frame.payload))
        case "event" where header.event == "agent":
            // Tool starts and results for this session, sent because the
            // connect frame asked for tool-events. Every other stream, and
            // anything that does not decode, is ignored as before.
            guard let frame = try? JSONDecoder().decode(GatewayEventFrame<GatewayAgentEvent>.self, from: data) else {
                return .ignored(event: "agent")
            }
            let events = self.reducer.apply(frame.payload)
            return events.isEmpty ? .ignored(event: "agent") : .conversation(events)
        case "event" where header.event == "session.approval":
            let frame = try JSONDecoder().decode(GatewayEventFrame<GatewaySessionApprovalEvent>.self, from: data)
            guard frame.payload.sessionKey == self.sessionKey else {
                return .ignored(event: header.event ?? "unknown")
            }
            return .approval(frame.payload)
        case "event" where header.event == "question.requested":
            // The model's ask_user, blocked until someone answers. A record
            // for another session, or one that does not decode, is not ours
            // to answer and is ignored rather than failing the reader.
            guard let frame = try? JSONDecoder().decode(GatewayEventFrame<GatewayQuestionRecord>.self, from: data),
                  frame.payload.sessionKey == nil || frame.payload.sessionKey == self.sessionKey
            else { return .ignored(event: "question.requested") }
            return .question(.requested(frame.payload))
        case "event" where header.event == "question.resolved":
            guard let frame = try? JSONDecoder().decode(GatewayEventFrame<GatewayQuestionResolvedEvent>.self, from: data)
            else { return .ignored(event: "question.resolved") }
            return .question(.resolved(frame.payload))
        case "event":
            return .ignored(event: header.event ?? "unknown")
        default:
            throw OpenClawGatewayError.invalidFrame
        }
    }

    public func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params) async throws -> Result
    {
        guard self.isConnected else { throw OpenClawGatewayError.notConnected }
        try await self.typedRequestQueue.acquire()
        do {
            try Task.checkCancellation()
            let result: Result = try await self.performRequest(method: method, params: params)
            self.logger.info("[gateway] typed request completed method=\(method, privacy: .public)")
            await self.typedRequestQueue.release()
            return result
        } catch {
            self.logger.error("[gateway] typed request failed method=\(method, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            await self.typedRequestQueue.release()
            throw error
        }
    }

    private func performRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params) async throws -> Result
    {
        let id = self.requestID()
        let request = GatewayRequest(id: id, method: method, params: params)
        try await self.transport.send(try JSONEncoder().encode(request))
        self.logger.info("[gateway] sent typed request method=\(method, privacy: .public)")

        while true {
            let data = try await self.transport.receive()
            let header = try JSONDecoder().decode(FrameHeader.self, from: data)
            guard header.type == "res", header.id == id else {
                self.bufferedInbound.append(try self.decodeInbound(data))
                continue
            }
            let response = try JSONDecoder().decode(GatewayRPCResponseFrame<Result>.self, from: data)
            guard response.ok else {
                throw OpenClawGatewayError.rejected(
                    code: response.error?.code ?? "REQUEST_REJECTED",
                    message: response.error?.message ?? "Gateway rejected the request")
            }
            guard let payload = response.payload else {
                throw OpenClawGatewayError.invalidFrame
            }
            return payload
        }
    }

    public func disconnect() async {
        self.isConnected = false
        self.currentGatewayBootID = nil
        await self.typedRequestQueue.failWaitingRequests()
        await self.transport.close()
        self.logger.info("[gateway] disconnected")
    }
}

private actor TypedRequestQueue {
    private var active = false
    private var waitingOrder: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]

    func acquire() async throws {
        try Task.checkCancellation()
        guard self.active else {
            self.active = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waitingOrder.append(id)
                    self.waiting[id] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaitingRequest(id) }
        })
    }

    func release() {
        while let nextID = self.waitingOrder.first {
            self.waitingOrder.removeFirst()
            if let next = self.waiting.removeValue(forKey: nextID) {
                next.resume()
                return
            }
        }
        self.active = false
    }

    func failWaitingRequests() {
        let pending = self.waiting.values
        self.waiting.removeAll()
        self.waitingOrder.removeAll()
        for continuation in pending {
            continuation.resume(throwing: OpenClawGatewayError.notConnected)
        }
    }

    private func cancelWaitingRequest(_ id: UUID) {
        self.waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

public actor URLSessionGatewayTransport: GatewayTransport {
    private enum InboundResult {
        case data(Data)
        case failure(Error)
    }

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var socketGeneration = UUID()
    private var bufferedInbound: [InboundResult] = []
    private var waitingReceivers: [(UUID, CheckedContinuation<Data, Error>)] = []
    private var terminalError: Error?
    private let logger = Logger(subsystem: "app.operator.ios", category: "gateway-transport")

    public init(url: URL, timeout: TimeInterval = 30) {
        self.url = url
        self.session = URLSession(configuration: Self.configuration(handshakeTimeout: timeout))
    }

    /// `timeoutIntervalForResource` bounds the entire task, not a single
    /// exchange, so setting it on a websocket kills the connection that many
    /// seconds after it opens no matter how healthy it is. This socket carries
    /// both the chat stream and the native node, so a 30s cap meant the node
    /// dropped half a minute after every launch - the "your iPhone is
    /// disconnected" replies, and CFNetwork -1001 with
    /// transaction_duration_ms just over 30000 against a 101 upgrade.
    /// Only the handshake gets a deadline; the session keeps the URLSession
    /// default for total lifetime.
    static func configuration(handshakeTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = handshakeTimeout
        configuration.waitsForConnectivity = true
        return configuration
    }

    public func open() async throws {
        self.resetSocket(reason: .goingAway)
        let task = self.session.webSocketTask(with: self.url)
        self.task = task
        task.resume()
        self.logger.info("[gateway-transport] opened websocket reader")
        let generation = self.socketGeneration
        self.reader = Task { [weak self, task] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard !Task.isCancelled else { return }
                    let data: Data
                    switch message {
                    case let .data(value):
                        data = value
                    case let .string(value):
                        data = Data(value.utf8)
                    @unknown default:
                        await self?.receiveFailed(OpenClawGatewayError.invalidFrame, generation: generation)
                        return
                    }
                    await self?.received(data, generation: generation)
                }
            } catch is CancellationError {
                // close() and reopen() cancel the reader intentionally.
            } catch {
                await self?.receiveFailed(error, generation: generation)
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard let task else { throw OpenClawGatewayError.notConnected }
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        guard self.task != nil else { throw OpenClawGatewayError.notConnected }
        if !self.bufferedInbound.isEmpty {
            return try self.popBufferedInbound()
        }
        if let terminalError { throw terminalError }
        let receiverID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waitingReceivers.append((receiverID, continuation))
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelWaitingReceiver(receiverID) }
        })
    }

    public func close() async {
        self.resetSocket(reason: .goingAway)
    }

    private func received(_ data: Data, generation: UUID) {
        guard generation == self.socketGeneration, self.terminalError == nil else { return }
        self.bufferedInbound.append(.data(data))
        self.resumeWaitingReceivers()
    }

    private func receiveFailed(_ error: Error, generation: UUID) {
        guard generation == self.socketGeneration, self.terminalError == nil else { return }
        self.logger.error("[gateway-transport] websocket reader ended with an error")
        self.terminalError = error
        self.bufferedInbound.append(.failure(error))
        self.resumeWaitingReceivers()
    }

    private func popBufferedInbound() throws -> Data {
        switch self.bufferedInbound.removeFirst() {
        case let .data(data):
            return data
        case let .failure(error):
            throw error
        }
    }

    private func resumeWaitingReceivers() {
        while !self.waitingReceivers.isEmpty, !self.bufferedInbound.isEmpty {
            let (_, continuation) = self.waitingReceivers.removeFirst()
            do {
                continuation.resume(returning: try self.popBufferedInbound())
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if let terminalError, self.bufferedInbound.isEmpty {
            let waiters = self.waitingReceivers
            self.waitingReceivers.removeAll()
            for (_, continuation) in waiters {
                continuation.resume(throwing: terminalError)
            }
        }
    }

    private func cancelWaitingReceiver(_ id: UUID) {
        guard let index = self.waitingReceivers.firstIndex(where: { $0.0 == id }) else { return }
        let (_, continuation) = self.waitingReceivers.remove(at: index)
        continuation.resume(throwing: CancellationError())
    }

    private func resetSocket(reason: URLSessionWebSocketTask.CloseCode) {
        let hadSocket = self.task != nil
        self.socketGeneration = UUID()
        self.reader?.cancel()
        self.reader = nil
        self.task?.cancel(with: reason, reason: nil)
        self.task = nil
        self.bufferedInbound.removeAll()
        self.terminalError = nil
        let waiters = self.waitingReceivers
        self.waitingReceivers.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: OpenClawGatewayError.notConnected)
        }
        if hadSocket {
            self.logger.info("[gateway-transport] closed websocket reader")
        }
    }
}

private struct FrameHeader: Decodable {
    let type: String
    let id: String?
    let event: String?
}

private struct GatewayHelloPayload: Decodable, Sendable {
    struct Server: Decodable, Sendable {
        let bootId: String?
    }
    let server: Server?
}
