import Foundation

/// A question the model asked through OpenClaw's `ask_user` tool, as the
/// gateway records it. The model's run is blocked on the answer; until one
/// client resolves it, or it expires, the reply cannot continue. Operator is
/// the only client on the phone, so this is Operator's to answer.
///
/// Shapes are the gateway's 2026.7 question protocol, read from the bundled
/// 2026.9.1 runtime: a record holds one to three questions, each with zero or
/// two to four options, optionally accepting a free-text answer.
public enum GatewayQuestionStatus: String, Codable, Equatable, Sendable {
    case pending
    case answered
    case cancelled
    case expired
}

public struct GatewayQuestionOption: Decodable, Equatable, Sendable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct GatewayQuestion: Decodable, Equatable, Identifiable, Sendable {
    /// The model's key for this question inside the record; the answer is
    /// sent back under it.
    public let questionId: String
    /// A short chip, at most 12 characters.
    public let header: String
    public let question: String
    public let options: [GatewayQuestionOption]
    public let multiSelect: Bool
    /// Whether an answer outside the options is accepted.
    public let isOther: Bool
    /// A masked answer. The gateway does not support these yet and Operator
    /// cannot show one; it is cancelled rather than left pending.
    public let isSecret: Bool

    public var id: String { self.questionId }

    private enum CodingKeys: String, CodingKey {
        case questionId, header, question, options, multiSelect, isOther, isSecret
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.questionId = try values.decode(String.self, forKey: .questionId)
        self.header = try values.decodeIfPresent(String.self, forKey: .header) ?? ""
        self.question = try values.decode(String.self, forKey: .question)
        self.options = try values.decodeIfPresent([GatewayQuestionOption].self, forKey: .options) ?? []
        self.multiSelect = try values.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        self.isOther = try values.decodeIfPresent(Bool.self, forKey: .isOther) ?? false
        self.isSecret = try values.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        guard !self.questionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.options.count != 1, self.options.count <= 4,
              self.options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .questionId, in: values,
                debugDescription: "Question needs an id, a question and zero or two to four labelled options")
        }
    }

    public init(questionId: String, header: String, question: String, options: [GatewayQuestionOption],
                multiSelect: Bool = false, isOther: Bool = false, isSecret: Bool = false)
    {
        self.questionId = questionId
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.isOther = isOther
        self.isSecret = isSecret
    }

    /// A question with no options is a free-text one, whatever `isOther` says.
    public var acceptsFreeText: Bool { self.isOther || self.options.isEmpty }
}

/// Answers keyed by `questionId`. The gateway wraps them one level deeper on
/// the wire (`{"answers": {...}}`); that wrapping is the encoder's business.
public struct GatewayQuestionAnswers: Codable, Equatable, Sendable {
    public let answers: [String: [String]]

    public init(_ answers: [String: [String]]) {
        self.answers = answers
    }
}

public struct GatewayQuestionRecord: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let questions: [GatewayQuestion]
    public let sessionKey: String?
    public let runID: String?
    public let createdAtMilliseconds: Int
    public let expiresAtMilliseconds: Int
    public let status: GatewayQuestionStatus
    public let answers: GatewayQuestionAnswers?

    private enum CodingKeys: String, CodingKey {
        case id, questions, sessionKey, status, answers
        case runID = "runId"
        case createdAtMilliseconds = "createdAtMs"
        case expiresAtMilliseconds = "expiresAtMs"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.questions = try values.decode([GatewayQuestion].self, forKey: .questions)
        self.sessionKey = try values.decodeIfPresent(String.self, forKey: .sessionKey)
        self.runID = try values.decodeIfPresent(String.self, forKey: .runID)
        self.createdAtMilliseconds = try values.decode(Int.self, forKey: .createdAtMilliseconds)
        self.expiresAtMilliseconds = try values.decode(Int.self, forKey: .expiresAtMilliseconds)
        self.status = try values.decode(GatewayQuestionStatus.self, forKey: .status)
        self.answers = try values.decodeIfPresent(GatewayQuestionAnswers.self, forKey: .answers)
        guard !self.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...3).contains(self.questions.count),
              self.createdAtMilliseconds >= 0,
              self.expiresAtMilliseconds >= self.createdAtMilliseconds
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: values,
                debugDescription: "Question record has invalid identity, count or lifetime")
        }
    }

    public init(id: String, questions: [GatewayQuestion], sessionKey: String? = nil, runID: String? = nil,
                createdAtMilliseconds: Int, expiresAtMilliseconds: Int,
                status: GatewayQuestionStatus = .pending, answers: GatewayQuestionAnswers? = nil)
    {
        self.id = id
        self.questions = questions
        self.sessionKey = sessionKey
        self.runID = runID
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.status = status
        self.answers = answers
    }

    public func isActionable(at now: Date = .now) -> Bool {
        self.status == .pending
            && self.expiresAtMilliseconds > Int(now.timeIntervalSince1970 * 1_000)
    }
}

/// `question.resolved`: whoever answered, the record is finished.
public struct GatewayQuestionResolvedEvent: Decodable, Equatable, Sendable {
    public let id: String
    public let status: GatewayQuestionStatus
    public let answers: GatewayQuestionAnswers?

    public init(id: String, status: GatewayQuestionStatus, answers: GatewayQuestionAnswers? = nil) {
        self.id = id
        self.status = status
        self.answers = answers
    }
}

/// What `question.requested` and `question.resolved` mean to the chat.
public enum GatewayQuestionEvent: Equatable, Sendable {
    case requested(GatewayQuestionRecord)
    case resolved(GatewayQuestionResolvedEvent)
}

struct GatewayQuestionListParams: Encodable, Sendable {}

struct GatewayQuestionListResult: Decodable, Sendable {
    let questions: [GatewayQuestionRecord]
}

struct GatewayQuestionAnswerParams: Encodable, Sendable {
    let id: String
    let answers: GatewayQuestionAnswers
    let resolvedBy: String
}

struct GatewayQuestionCancelParams: Encodable, Sendable {
    let id: String
    let cancel = true
    let resolvedBy: String
}

/// `question.resolve`'s result: the gateway's own account of what it recorded.
public struct GatewayQuestionResolveResult: Decodable, Equatable, Sendable {
    public let status: GatewayQuestionStatus
    public let answers: GatewayQuestionAnswers?
}
