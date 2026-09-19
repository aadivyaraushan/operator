import Foundation
import XCTest
@testable import OperatorCore

/// These guard the rules openclaw applies when it normalizes a published
/// descriptor. Every one of them fails *silently* in production - the
/// descriptor is dropped, the tool never appears, and the model answers from
/// its own built-ins as if the connector did not exist. That is exactly how
/// the original bug hid, so each rule is asserted here rather than trusted.
final class GatewayNodeAgentToolsTests: XCTestCase {
    /// openclaw keeps a descriptor only when its command is one the node
    /// registered on connect; anything else is dropped on arrival.
    func testEveryPublishedCommandIsOneThisNodeActuallyRegisters() {
        let registered = Set(GatewayNativeNodeSurface.commands)
        for command in GatewayNodeAgentTools.publishedCommands {
            XCTAssertTrue(
                registered.contains(command),
                "\(command) is published as a tool but is not in the node's command surface, so the gateway will drop it")
        }
    }

    /// `^[A-Za-z][A-Za-z0-9_-]{0,63}$`. The dotted command name is the usual
    /// mistake here: `reminders.list` is not a legal tool name.
    func testToolNamesAreProviderSafe() {
        let pattern = try? NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_-]{0,63}$")
        for descriptor in GatewayNodeAgentTools.descriptors {
            let range = NSRange(descriptor.name.startIndex ..< descriptor.name.endIndex, in: descriptor.name)
            XCTAssertNotNil(
                pattern?.firstMatch(in: descriptor.name, range: range),
                "\(descriptor.name) is not a provider-safe tool name")
            XCTAssertFalse(descriptor.name.contains("."), "\(descriptor.name) must not be the dotted command name")
        }
    }

    /// Publishing a tool is what lets the model call a command unprompted, so
    /// this is where reads-before-writes is enforced for the agent.
    func testNoWriteOrHandOffCommandIsEverPublished() {
        let forbidden = [
            "sms.compose", "whatsapp.compose", "connections.write",
            "apps.open", "maps.search", "maps.directions",
            "youtube.open", "podcasts.open", "notion.call",
        ]
        let published = Set(GatewayNodeAgentTools.publishedCommands)
        for command in forbidden {
            XCTAssertFalse(
                published.contains(command),
                "\(command) can change something or hand off to another app; it must not be a model-callable tool")
        }
    }

    /// The gateway deduplicates on pluginId + name and keeps the first, so a
    /// collision would silently hide a connector.
    func testDescriptorsAreUniqueByName() {
        let names = GatewayNodeAgentTools.descriptors.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "two descriptors share a name; one would be dropped")
    }

    func testEveryDescriptorCarriesTheFieldsNormalizationRequires() {
        XCTAssertFalse(GatewayNodeAgentTools.descriptors.isEmpty)
        XCTAssertLessThanOrEqual(GatewayNodeAgentTools.descriptors.count, 128)
        for descriptor in GatewayNodeAgentTools.descriptors {
            XCTAssertFalse(descriptor.pluginId.isEmpty)
            XCTAssertFalse(descriptor.description.isEmpty)
            XCTAssertLessThanOrEqual(descriptor.description.count, 1024)
            XCTAssertFalse(descriptor.command.isEmpty)
            XCTAssertNotEqual(descriptor.pluginId, "node-mcp", "the node-mcp id is reserved and needs an MCP shape")
        }
    }

    /// The five permission-only connectors are the ones the demo and the Mac
    /// checklist both depend on; losing one would make Stage 3 unprovable.
    func testTheOnDeviceReadConnectorsAreAllReachable() {
        let published = Set(GatewayNodeAgentTools.publishedCommands)
        for command in ["reminders.list", "calendar.events", "contacts.search",
                        "photos.latest", "music.nowPlaying", "device.status"]
        {
            XCTAssertTrue(published.contains(command), "\(command) is not reachable by the agent")
        }
    }

    /// A required argument that is not declared in `properties` would be
    /// unfillable, and the model would have no way to call the tool at all.
    func testRequiredArgumentsAreDeclared() {
        for descriptor in GatewayNodeAgentTools.descriptors {
            for required in descriptor.parameters.required {
                XCTAssertNotNil(
                    descriptor.parameters.properties[required],
                    "\(descriptor.name) requires \(required) but never declares it")
            }
        }
    }

    /// The handlers reject any key they do not expect, so a descriptor that
    /// advertises a parameter its command will not take makes the tool
    /// unusable: the model fills the argument in good faith and the call comes
    /// back INVALID_REQUEST. That is what happened to calendar.events, which
    /// takes nothing at all and was advertised with three arguments - the
    /// agent reported the connector "rejecting its date-range parameters".
    func testCommandsThatTakeNoArgumentsAdvertiseNone() throws {
        let takeNothing = ["calendar.events", "music.nowPlaying", "device.status"]
        for command in takeNothing {
            let descriptor = try XCTUnwrap(
                GatewayNodeAgentTools.descriptors.first { $0.command == command },
                "\(command) is no longer published")
            XCTAssertTrue(
                descriptor.parameters.properties.isEmpty,
                "\(command) accepts no parameters, so advertising any makes every call fail")
            XCTAssertTrue(descriptor.parameters.required.isEmpty)
        }
    }

    /// The mirror of the rule above: a command that does take arguments must
    /// say so, or the model has no way to pass them.
    func testCommandsThatTakeArgumentsAdvertiseThem() throws {
        let expected = [
            "reminders.list": ["limit"],
            "photos.latest": ["limit"],
            "contacts.search": ["limit", "query"],
            "music.search": ["limit", "query"],
            "weather.forecast": ["latitude", "longitude"],
        ]
        for (command, keys) in expected {
            let descriptor = try XCTUnwrap(
                GatewayNodeAgentTools.descriptors.first { $0.command == command })
            XCTAssertEqual(
                descriptor.parameters.properties.keys.sorted(), keys.sorted(),
                "\(command) advertises a different argument set than its handler accepts")
        }
    }

    func testEncodesTheShapeTheGatewayParses() throws {
        let request = GatewayRequestFactory.nodePluginToolsUpdate(requestID: "req-1")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "node.pluginTools.update")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let tools = try XCTUnwrap(params["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, GatewayNodeAgentTools.descriptors.count)
        let first = try XCTUnwrap(tools.first)
        for key in ["pluginId", "name", "description", "command", "parameters"] {
            XCTAssertNotNil(first[key], "a descriptor is missing \(key)")
        }
        let schema = try XCTUnwrap(first["parameters"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertNotNil(schema["properties"])
    }
}
