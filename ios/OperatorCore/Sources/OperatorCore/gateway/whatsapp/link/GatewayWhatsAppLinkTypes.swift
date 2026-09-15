import Foundation

public enum WhatsAppLinkPhase: String, Decodable, Equatable, Sendable {
    case waitingForCode = "waiting_for_code"
    case codeReady = "code_ready"
    case finishing
    case cancelled
    case failed
    case linked
}

public struct WhatsAppLinkOperation: Decodable, Equatable, Sendable {
    public let operationID: String
    public let phase: WhatsAppLinkPhase

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case phase
        case pairCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.operationID = try Self.operationID(from: container)
        self.phase = try container.decode(WhatsAppLinkPhase.self, forKey: .phase)
        guard !container.contains(.pairCode) else {
            throw DecodingError.dataCorruptedError(forKey: .pairCode, in: container, debugDescription: "Pair codes are only available from status")
        }
    }

    private static func operationID(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        let value = try container.decode(String.self, forKey: .operationID)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .operationID, in: container, debugDescription: "operationId must not be empty")
        }
        return value
    }
}

public struct WhatsAppLinkStatus: Decodable, Equatable, Sendable {
    public let operationID: String
    public let phase: WhatsAppLinkPhase
    public let pairCode: String?
    public let failureCode: String?

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case phase
        case pairCode
        case failureCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operationID = try container.decode(String.self, forKey: .operationID)
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .operationID, in: container, debugDescription: "operationId must not be empty")
        }
        let phase = try container.decode(WhatsAppLinkPhase.self, forKey: .phase)
        let pairCode = try container.decodeIfPresent(String.self, forKey: .pairCode)
        if let pairCode {
            guard phase == .codeReady, !pairCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .pairCode, in: container, debugDescription: "Pair code is only valid in code_ready status")
            }
        }
        self.operationID = operationID
        self.phase = phase
        self.pairCode = pairCode
        let failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        self.failureCode = phase == .failed && ["verification_required", "code_expired", "client_outdated", "pairing_failed"].contains(failureCode ?? "") ? failureCode : nil
    }
}

struct WhatsAppLinkStartParams: Encodable, Sendable {
    let phone: String
}

struct WhatsAppLinkOperationParams: Encodable, Sendable {
    let operationId: String
}
