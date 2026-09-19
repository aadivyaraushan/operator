import Foundation

public enum GatewayApprovalKind: String, Codable, Equatable, Sendable {
    case exec
    case plugin
    case systemAgent = "system-agent"
}

public enum GatewayApprovalDecision: String, Codable, Equatable, Sendable {
    case allowOnce = "allow-once"
    case allowAlways = "allow-always"
    case deny
}

public enum GatewayApprovalStatus: String, Codable, Equatable, Sendable {
    case pending
    case allowed
    case denied
    case expired
    case cancelled
}

/// The Gateway's reviewer-safe summary. It deliberately excludes request internals.
public struct GatewayApprovalPresentation: Decodable, Equatable, Sendable {
    public let kind: GatewayApprovalKind
    public let title: String
    public let detail: String
    public let warning: String?
    public let allowedDecisions: [GatewayApprovalDecision]

    private enum CodingKeys: String, CodingKey {
        case kind
        case commandText
        case commandPreview
        case warningText
        case title
        case description
        case detail
        case allowedDecisions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try values.decode(GatewayApprovalKind.self, forKey: .kind)
        self.allowedDecisions = try values.decode([GatewayApprovalDecision].self, forKey: .allowedDecisions)
        guard !self.allowedDecisions.isEmpty,
              Set(self.allowedDecisions).count == self.allowedDecisions.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .allowedDecisions,
                in: values,
                debugDescription: "Approval decisions must be a nonempty unique server list")
        }

        switch self.kind {
        case .exec:
            let command = try values.decode(String.self, forKey: .commandText)
            self.title = "Command approval"
            self.detail = try values.decodeIfPresent(String.self, forKey: .commandPreview) ?? command
            self.warning = try values.decodeIfPresent(String.self, forKey: .warningText)
        case .plugin, .systemAgent:
            self.title = try values.decode(String.self, forKey: .title)
            self.detail = try values.decode(String.self, forKey: .description)
            self.warning = try values.decodeIfPresent(String.self, forKey: .detail)
        }

        guard !self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "Approval presentation cannot be blank")
        }
    }
}

public struct GatewayApprovalSnapshot: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let createdAtMilliseconds: Int
    public let expiresAtMilliseconds: Int
    public let status: GatewayApprovalStatus
    public let decision: GatewayApprovalDecision?
    public let presentation: GatewayApprovalPresentation

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAtMilliseconds = "createdAtMs"
        case expiresAtMilliseconds = "expiresAtMs"
        case status
        case decision
        case presentation
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.createdAtMilliseconds = try values.decode(Int.self, forKey: .createdAtMilliseconds)
        self.expiresAtMilliseconds = try values.decode(Int.self, forKey: .expiresAtMilliseconds)
        self.status = try values.decode(GatewayApprovalStatus.self, forKey: .status)
        self.decision = try values.decodeIfPresent(GatewayApprovalDecision.self, forKey: .decision)
        self.presentation = try values.decode(GatewayApprovalPresentation.self, forKey: .presentation)
        guard !self.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.createdAtMilliseconds >= 0,
              self.expiresAtMilliseconds >= self.createdAtMilliseconds
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: values,
                debugDescription: "Approval snapshot has invalid identity or lifetime")
        }
    }

    public func isActionable(at now: Date = .now) -> Bool {
        self.status == .pending
            && self.expiresAtMilliseconds > Int(now.timeIntervalSince1970 * 1_000)
            && !self.presentation.allowedDecisions.isEmpty
    }
}

public struct GatewaySessionApprovalEvent: Decodable, Equatable, Sendable {
    public enum Phase: String, Decodable, Equatable, Sendable {
        case pending
        case terminal
    }

    public let sessionKey: String
    public let updatedAtMilliseconds: Int
    public let phase: Phase
    public let approval: GatewayApprovalSnapshot

    private enum CodingKeys: String, CodingKey {
        case sessionKey
        case updatedAtMilliseconds = "updatedAtMs"
        case phase
        case approval
    }
}

public struct GatewayApprovalReplay: Decodable, Equatable, Sendable {
    public let sessionKey: String
    public let updatedAtMilliseconds: Int
    public let approvals: [GatewayApprovalSnapshot]
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionKey
        case updatedAtMilliseconds = "updatedAtMs"
        case approvals
        case truncated
    }

    public init(
        sessionKey: String,
        updatedAtMilliseconds: Int,
        approvals: [GatewayApprovalSnapshot],
        truncated: Bool)
    {
        self.sessionKey = sessionKey
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.approvals = approvals
        self.truncated = truncated
    }
}

public struct GatewaySessionsMessagesSubscribeParams: Encodable, Sendable {
    public let key: String
    public let includeApprovals: Bool
}

public struct GatewaySessionsMessagesSubscribeResult: Decodable, Sendable {
    public let subscribed: Bool
    public let key: String
    public let approvalReplay: GatewayApprovalReplay?
}

public struct GatewayApprovalResolveParams: Encodable, Sendable {
    public let id: String
    public let kind: GatewayApprovalKind
    public let decision: GatewayApprovalDecision
}

public struct GatewayApprovalResolveResult: Decodable, Sendable {
    public let applied: Bool
    public let approval: GatewayApprovalSnapshot
}
