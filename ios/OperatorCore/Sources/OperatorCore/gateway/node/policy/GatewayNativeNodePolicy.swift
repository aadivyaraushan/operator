import Foundation

public enum GatewayNativeNodePolicyState: Equatable, Sendable {
    case ready
    case waitingForApply
    case missing(baseHash: String, existingAllow: [String])
}

public extension OpenClawGatewayConnection {
    func nativeNodePolicyState() async throws -> GatewayNativeNodePolicyState {
        let response: GatewayNativeNodeConfigResponse = try await request(
            method: "config.get", params: GatewayNativeNodeConfigGetParams())
        guard response.valid else { throw OpenClawGatewayError.invalidFrame }

        let policy = try response.config.commandPolicy()
        let required = GatewayNativeNodeSurface.commandPolicyAllow
        if policy.deny?.contains(where: { denied in
            required.contains(denied.trimmingCharacters(in: .whitespacesAndNewlines))
        }) == true {
            throw OpenClawGatewayError.invalidFrame
        }

        let revision = response.configRevisionHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let applied = response.appliedConfigHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !revision.isEmpty else { throw OpenClawGatewayError.invalidFrame }
        if revision != applied { return .waitingForApply }
        let baseHash = response.hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseHash.isEmpty else { throw OpenClawGatewayError.invalidFrame }
        let existingAllow = policy.allow ?? []
        let hasMissingRequiredCommand = required.contains { command in
            !existingAllow.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == command }
        }
        return hasMissingRequiredCommand
            ? .missing(baseHash: baseHash, existingAllow: existingAllow)
            : .ready
    }

    func installNativeNodeAllowPolicy(baseHash: String, existingAllow: [String]) async throws {
        let trimmedHash = baseHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHash.isEmpty else { throw OpenClawGatewayError.invalidFrame }
        let mergedAllow = Self.mergedNativeNodeAllow(existingAllow)
        guard let data = try? JSONEncoder().encode(GatewayNativeNodePolicyPatch(allow: mergedAllow)),
              let raw = String(data: data, encoding: .utf8)
        else { throw OpenClawGatewayError.invalidFrame }
        let result: GatewayNativeNodeConfigPatchResult = try await request(
            method: "config.patch",
            params: GatewayNativeNodeConfigPatchParams(
                raw: raw,
                baseHash: trimmedHash))
        guard result.ok else { throw OpenClawGatewayError.invalidFrame }
    }

    private static func mergedNativeNodeAllow(_ existingAllow: [String]) -> [String] {
        var merged = existingAllow
        for command in GatewayNativeNodeSurface.commandPolicyAllow where !merged.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == command
        }) {
            merged.append(command)
        }
        return merged
    }
}

private struct GatewayNativeNodeConfigGetParams: Encodable, Sendable {}

private struct GatewayNativeNodeConfigPatchParams: Encodable, Sendable {
    let raw: String
    let baseHash: String
}

private struct GatewayNativeNodeConfigPatchResult: Decodable, Sendable {
    let ok: Bool
}

private struct GatewayNativeNodePolicyPatch: Encodable, Sendable {
    struct Gateway: Encodable, Sendable {
        struct Nodes: Encodable, Sendable {
            struct Commands: Encodable, Sendable { let allow: [String] }
            let commands: Commands
        }
        let nodes: Nodes
    }
    let gateway: Gateway

    init(allow: [String]) {
        self.gateway = Gateway(nodes: .init(commands: .init(allow: allow)))
    }
}

private struct GatewayNativeNodeConfigResponse: Decodable, Sendable {
    let valid: Bool
    let hash: String
    let configRevisionHash: String
    let appliedConfigHash: String?
    let config: GatewayNativeNodeConfigValue
}

private enum GatewayNativeNodeConfigValue: Decodable, Sendable {
    case object([String: GatewayNativeNodeConfigValue])
    case array([GatewayNativeNodeConfigValue])
    case string(String)
    case scalar

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if container.decodeNil() { self = .scalar }
        else if (try? container.decode(Bool.self)) != nil || (try? container.decode(Double.self)) != nil { self = .scalar }
        else { throw DecodingError.typeMismatch(Self.self, .init(codingPath: decoder.codingPath, debugDescription: "unsupported config value")) }
    }

    func commandPolicy() throws -> (allow: [String]?, deny: [String]?) {
        guard case .object(let root) = self else { throw OpenClawGatewayError.invalidFrame }
        var current = root
        for key in ["gateway", "nodes", "commands"] {
            guard let next = current[key] else { return (nil, nil) }
            guard case .object(let object) = next else { throw OpenClawGatewayError.invalidFrame }
            current = object
        }
        return (try Self.strings(current["allow"]), try Self.strings(current["deny"]))
    }

    private static func strings(_ value: Self?) throws -> [String]? {
        guard let value else { return nil }
        guard case .array(let values) = value else { throw OpenClawGatewayError.invalidFrame }
        return try values.map {
            guard case .string(let string) = $0 else { throw OpenClawGatewayError.invalidFrame }
            return string
        }
    }
}
