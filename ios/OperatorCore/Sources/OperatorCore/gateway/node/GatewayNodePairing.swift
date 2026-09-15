import Foundation
import OSLog

// openclaw resolves a node's allowlist from its own per-platform defaults
// plus gateway.nodes.commands.allow, and silently *withholds* any declared
// command in neither - which makes the pending pairing surface differ from
// what was advertised, and pairing then fails closed. Measured against
// openclaw 2026.9.1, the iOS defaults are: location.get, device.info,
// device.status, contacts.search, calendar.events, reminders.list,
// photos.latest, motion.activity, motion.pedometer and the camera commands.
//
// So two rules hold here. Names that openclaw already has must match it
// exactly - contacts.search and photos.latest, not the contacts.resolve and
// photos.search this once used. And anything openclaw has no default for -
// music and weather - must appear in commandPolicyAllow or it cannot be
// reached at all.
public enum GatewayNativeNodeSurface {
    public static let messageComposeCommand = "sms.compose"
    /// Sends without a confirmation tap, through a shortcut the owner builds
    /// once. Gated by its own connector grant; see ConnectorCatalog.
    public static let messageSendCommand = "sms.send"
    public static let capabilities = ["location", "calendar", "sms", "maps", "apps", "whatsapp", "accounts", "notion", "media", "reminders", "contacts", "photos", "music", "weather", "device"]
    public static let commands = ["location.get", "calendar.events", "reminders.list", "contacts.search", "photos.latest", "music.nowPlaying", "music.search",
                                  "weather.forecast", "device.status", Self.messageComposeCommand, Self.messageSendCommand, "maps.search", "maps.directions", "apps.open", "whatsapp.chats", "whatsapp.messages", "whatsapp.sync", "whatsapp.compose", "connections.read", "connections.write", "connections.describe", "notion.tools", "notion.call", "youtube.search", "youtube.open", "podcasts.search", "podcasts.open"]
    public static let commandPolicyAllow = ["weather.forecast", "device.status", "music.nowPlaying", "music.search", Self.messageComposeCommand, Self.messageSendCommand, "maps.search", "maps.directions", "apps.open", "whatsapp.chats", "whatsapp.messages", "whatsapp.sync", "whatsapp.compose", "connections.read", "connections.write", "connections.describe", "notion.tools", "notion.call", "youtube.search", "youtube.open", "podcasts.search", "podcasts.open"]

    static func matches(_ surface: GatewayNodePairingSurface) -> Bool {
        Self.matches(
            capabilities: surface.capabilities,
            commands: surface.commands,
            permissions: surface.permissions)
    }

    static func matches(_ surface: GatewayNodePendingPairing) -> Bool {
        Self.matches(
            capabilities: surface.capabilities,
            commands: surface.commands,
            permissions: surface.permissions)
    }

    private static func matches(
        capabilities: [String],
        commands: [String],
        permissions: GatewayNodeEmptyPermissions?) -> Bool
    {
        Self.isExact(capabilities, expected: Self.capabilities)
            && Self.isExact(commands, expected: Self.commands)
            && permissions?.isEmpty != false
    }

    private static func isExact(_ actual: [String], expected: [String]) -> Bool {
        actual.count == expected.count && Set(actual) == Set(expected)
    }
}

public extension OpenClawGatewayConnection {
    /// Device-role approval must happen before the node socket can connect.
    /// It is separate from the exact command-surface approval below.
    func approveOwnNativeDeviceRole() async throws {
        let listing: NativeDeviceRoleList = try await self.request(
            method: "device.pair.list", params: GatewayNodePairingListParams())
        let pending = listing.pending.filter { $0.deviceId == self.authenticatedDeviceID }
        guard pending.count <= 1 else { throw OpenClawGatewayError.invalidFrame }
        guard let request = pending.first else { return }
        guard request.publicKey == self.authenticatedPublicKey,
              request.role == "node", request.roles == ["node"], request.scopes?.isEmpty != false,
              request.clientId == "node-host", request.clientMode == "node", request.deviceFamily == "iPhone",
              let requestID = request.requestId, !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            GatewayNodePairingLog.logger.error("[node-pairing] rejected unexpected own device-role request")
            throw OpenClawGatewayError.invalidFrame
        }
        let result: NativeDeviceRoleApproval = try await self.request(
            method: "device.pair.approve", params: GatewayNodePairingApproveParams(requestID: requestID))
        guard result.requestId == requestID,
              result.device.deviceId == self.authenticatedDeviceID,
              result.device.publicKey == self.authenticatedPublicKey,
              let roles = result.device.roles, roles.contains("node"),
              Set(roles).isSubset(of: ["operator", "node"])
        else { throw OpenClawGatewayError.invalidFrame }
        GatewayNodePairingLog.logger.info("[node-pairing] approved matching app device for node role")
    }

    /// Approves this app's exact native node surface, or reports that it already matches.
    func prepareNativeNode() async throws -> Bool {
        let expectedDeviceID = self.authenticatedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedDeviceID.isEmpty else { throw OpenClawGatewayError.invalidFrame }

        let listing: GatewayNodePairingList = try await self.request(
            method: "node.pair.list",
            params: GatewayNodePairingListParams())
        let ownPending = listing.pending.filter { $0.nodeID == expectedDeviceID }
        let ownPaired = listing.paired.filter { $0.nodeID == expectedDeviceID }
        GatewayNodePairingLog.logger.info(
            "[node-pairing] inspected ownPending=\(ownPending.count) ownPaired=\(ownPaired.count)")

        guard ownPending.count <= 1 else {
            GatewayNodePairingLog.logger.error("[node-pairing] rejected ambiguous own pending surfaces")
            throw OpenClawGatewayError.invalidFrame
        }
        if let pending = ownPending.first {
            let requestID = pending.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestID.isEmpty, GatewayNativeNodeSurface.matches(pending) else {
                GatewayNodePairingLog.logger.error("[node-pairing] rejected unexpected pending surface")
                throw OpenClawGatewayError.invalidFrame
            }
            let approved: GatewayNodePairingApproval = try await self.request(
                method: "node.pair.approve",
                params: GatewayNodePairingApproveParams(requestID: requestID))
            guard approved.requestID == requestID,
                  approved.node.nodeID == expectedDeviceID,
                  GatewayNativeNodeSurface.matches(approved.node)
            else {
                GatewayNodePairingLog.logger.error("[node-pairing] rejected mismatched approval response")
                throw OpenClawGatewayError.invalidFrame
            }
            GatewayNodePairingLog.logger.info("[node-pairing] approved exact native surface")
            return true
        }

        guard ownPaired.count == 1,
              let paired = ownPaired.first,
              GatewayNativeNodeSurface.matches(paired)
        else {
            GatewayNodePairingLog.logger.error("[node-pairing] exact own surface unavailable")
            throw OpenClawGatewayError.invalidFrame
        }
        GatewayNodePairingLog.logger.info("[node-pairing] exact native surface already approved")
        return false
    }
}

struct GatewayNodePairingListParams: Encodable, Sendable {}

struct GatewayNodePairingApproveParams: Encodable, Sendable {
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
    }
}

struct GatewayNodePairingList: Decodable, Sendable {
    let pending: [GatewayNodePendingPairing]
    let paired: [GatewayNodePairingSurface]
}

struct GatewayNodePendingPairing: Decodable, Sendable {
    let requestID: String
    let nodeID: String
    let capabilities: [String]
    let commands: [String]
    let permissions: GatewayNodeEmptyPermissions?

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case nodeID = "nodeId"
        case capabilities = "caps"
        case commands
        case permissions
    }
}

struct GatewayNodePairingApproval: Decodable, Sendable {
    let requestID: String
    let node: GatewayNodePairingSurface

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case node
    }
}

struct GatewayNodePairingSurface: Decodable, Sendable {
    let nodeID: String
    let capabilities: [String]
    let commands: [String]
    let permissions: GatewayNodeEmptyPermissions?

    enum CodingKeys: String, CodingKey {
        case nodeID = "nodeId"
        case capabilities = "caps"
        case commands
        case permissions
    }
}

struct GatewayNodeEmptyPermissions: Decodable, Sendable {
    let isEmpty: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GatewayNodeDynamicCodingKey.self)
        self.isEmpty = container.allKeys.isEmpty
    }
}

private struct GatewayNodeDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private enum GatewayNodePairingLog {
    static let logger = Logger(subsystem: "app.operator.ios", category: "node-pairing")
}

private struct NativeDeviceRoleList: Decodable, Sendable { let pending: [NativeDeviceRole] }
private struct NativeDeviceRoleApproval: Decodable, Sendable {
    let requestId: String
    let device: NativeDeviceRole
}
private struct NativeDeviceRole: Decodable, Sendable {
    let requestId: String?
    let deviceId: String
    let publicKey: String
    let role: String?
    let roles: [String]?
    let scopes: [String]?
    let clientId: String?
    let clientMode: String?
    let deviceFamily: String?
}
