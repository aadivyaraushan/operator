import Foundation

public struct GatewayChatEvent: Decodable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case status
        case delta
        case final
        case error
        case aborted
    }

    public let runID: String
    public let sessionKey: String
    public let sequence: Int
    public let state: State
    public let deltaText: String?
    public let replace: Bool
    public let messageText: String?
    public let errorMessage: String?

    public init(
        runID: String,
        sessionKey: String,
        sequence: Int,
        state: State,
        deltaText: String? = nil,
        replace: Bool = false,
        messageText: String? = nil,
        errorMessage: String? = nil)
    {
        self.runID = runID
        self.sessionKey = sessionKey
        self.sequence = sequence
        self.state = state
        self.deltaText = deltaText
        self.replace = replace
        self.messageText = messageText
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case sessionKey
        case sequence = "seq"
        case state
        case deltaText
        case replace
        case message
        case errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try container.decode(String.self, forKey: .runID)
        self.sessionKey = try container.decode(String.self, forKey: .sessionKey)
        self.sequence = try container.decode(Int.self, forKey: .sequence)
        self.state = try container.decode(State.self, forKey: .state)
        self.deltaText = try container.decodeIfPresent(String.self, forKey: .deltaText)
        self.replace = try container.decodeIfPresent(Bool.self, forKey: .replace) ?? false
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        if let text = try? container.decode(String.self, forKey: .message) {
            self.messageText = text
        } else if let projection = try? container.decode(MessageProjection.self, forKey: .message) {
            self.messageText = projection.visibleText
        } else {
            self.messageText = nil
        }
    }
}

private struct MessageProjection: Decodable {
    struct Content: Decodable {
        let type: String?
        let text: String?
    }

    let text: String?
    let content: [Content]?

    var visibleText: String? {
        if let text, !text.isEmpty {
            return text
        }
        let joined = (self.content ?? [])
            .filter { $0.type == nil || $0.type == "text" }
            .compactMap(\.text)
            .joined()
        return joined.isEmpty ? nil : joined
    }
}

/// One `agent` event as the gateway broadcasts it to a client that connected
/// with the `tool-events` capability. The tool's arguments come through as
/// the runtime sends them (it redacts secrets before broadcasting); results
/// do not, only whether the call failed.
public struct GatewayAgentEvent: Decodable, Equatable, Sendable {
    public let runID: String
    public let sessionKey: String?
    public let sequence: Int?
    public let stream: String
    public let phase: String?
    public let toolName: String?
    public let toolCallID: String?
    public let isError: Bool
    public let arguments: [String: JSONValue]

    public init(
        runID: String, sessionKey: String? = nil, sequence: Int? = nil, stream: String,
        phase: String? = nil, toolName: String? = nil, toolCallID: String? = nil, isError: Bool = false,
        arguments: [String: JSONValue] = [:])
    {
        self.runID = runID
        self.sessionKey = sessionKey
        self.sequence = sequence
        self.stream = stream
        self.phase = phase
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.isError = isError
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case sessionKey
        case sequence = "seq"
        case stream
        case data
    }

    private enum DataKeys: String, CodingKey {
        case phase, name, toolCallId, isError, args
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try container.decode(String.self, forKey: .runID)
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        self.sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
        self.stream = try container.decode(String.self, forKey: .stream)
        guard let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data) else {
            self.phase = nil; self.toolName = nil; self.toolCallID = nil; self.isError = false; self.arguments = [:]
            return
        }
        self.phase = try? data.decodeIfPresent(String.self, forKey: .phase)
        self.toolName = try? data.decodeIfPresent(String.self, forKey: .name)
        self.toolCallID = try? data.decodeIfPresent(String.self, forKey: .toolCallId)
        self.isError = (try? data.decodeIfPresent(Bool.self, forKey: .isError)) ?? false
        self.arguments = (try? data.decodeIfPresent(JSONValue.self, forKey: .args))?.objectValue ?? [:]
    }
}

/// What the agent is doing inside a run, as far as the app shows it: a tool
/// starting, with its arguments, and a tool finishing.
public enum GatewayRunActivity: Equatable, Sendable {
    case toolStarted(tool: String, callID: String, arguments: [String: JSONValue])
    case toolFinished(tool: String, callID: String, isError: Bool)

    /// Nil for every stream and phase the app does not show.
    public init?(_ event: GatewayAgentEvent) {
        guard event.stream == "tool", let tool = event.toolName, !tool.isEmpty else { return nil }
        let callID = event.toolCallID ?? tool
        switch event.phase {
        case "start": self = .toolStarted(tool: tool, callID: callID, arguments: event.arguments)
        case "result": self = .toolFinished(tool: tool, callID: callID, isError: event.isError)
        default: return nil
        }
    }
}

public enum GatewayConversationEvent: Equatable, Sendable {
    case working(runID: String)
    case activity(runID: String, GatewayRunActivity)
    case stream(runID: String, text: String)
    case reply(runID: String, text: String)
    case failed(runID: String, message: String)
    case stopped(runID: String)
}

public struct GatewayEventReducer: Sendable {
    private struct Run: Sendable {
        var text = ""
        var lastSequence = -1
        var announcedWorking = false
    }

    private let sessionKey: String
    private var runs: [String: Run] = [:]
    private var finished = Set<String>()
    private var finishedOrder: [String] = []
    private let finishedLimit = 128

    public init(sessionKey: String) {
        self.sessionKey = sessionKey
    }

    public mutating func apply(_ event: GatewayChatEvent) -> [GatewayConversationEvent] {
        guard event.sessionKey == self.sessionKey, !self.finished.contains(event.runID) else {
            return []
        }
        var run = self.runs[event.runID] ?? Run()
        guard event.sequence > run.lastSequence else {
            return []
        }
        run.lastSequence = event.sequence
        var output: [GatewayConversationEvent] = []
        if !run.announcedWorking {
            run.announcedWorking = true
            output.append(.working(runID: event.runID))
        }

        switch event.state {
        case .status:
            self.runs[event.runID] = run
        case .delta:
            if event.replace {
                run.text = event.deltaText ?? ""
            } else {
                run.text += event.deltaText ?? ""
            }
            self.runs[event.runID] = run
            if !run.text.isEmpty {
                output.append(.stream(runID: event.runID, text: run.text))
            }
        case .final:
            let streamedReply = run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : run.text
            let reply = streamedReply ?? event.messageText
            if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(.reply(runID: event.runID, text: reply))
            } else {
                output.append(.failed(
                    runID: event.runID,
                    message: "No readable result was received. Completion isn't verified."))
            }
            self.finish(event.runID)
        case .error:
            output.append(.failed(
                runID: event.runID,
                message: event.errorMessage ?? "Operator hit an error"))
            self.finish(event.runID)
        case .aborted:
            output.append(.stopped(runID: event.runID))
            self.finish(event.runID)
        }
        return output
    }

    /// Activity for a run the reducer has not finished. Agent events carry
    /// their own sequence, separate from chat events, so only the session and
    /// the finished set are checked; a first activity announces the run as
    /// working like a first chat event would.
    public mutating func apply(_ event: GatewayAgentEvent) -> [GatewayConversationEvent] {
        guard event.sessionKey == nil || event.sessionKey == self.sessionKey,
              !self.finished.contains(event.runID),
              let activity = GatewayRunActivity(event)
        else { return [] }
        var run = self.runs[event.runID] ?? Run()
        var output: [GatewayConversationEvent] = []
        if !run.announcedWorking {
            run.announcedWorking = true
            output.append(.working(runID: event.runID))
        }
        self.runs[event.runID] = run
        output.append(.activity(runID: event.runID, activity))
        return output
    }

    private mutating func finish(_ runID: String) {
        self.runs.removeValue(forKey: runID)
        self.finished.insert(runID)
        self.finishedOrder.append(runID)
        if self.finishedOrder.count > self.finishedLimit {
            let oldest = self.finishedOrder.removeFirst()
            self.finished.remove(oldest)
        }
    }
}
