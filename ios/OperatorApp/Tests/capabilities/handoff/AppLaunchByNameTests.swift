import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

/// "open google docs" had no route: apps.open only knew a short list of
/// websites. These cover opening an installed app by its name.
@MainActor
final class AppLaunchByNameTests: XCTestCase {
    private let table = AppLinkTable(entries: [
        .init(names: ["google docs", "docs"], link: "googledocs://", bundleID: "com.google.Docs"),
        .init(names: ["camera"], link: nil, bundleID: "com.apple.camera"),
    ])

    private func service(_ launcher: RecordingLauncher, lookup: FixedLookup = .init(nil), active: Bool = true) -> ForegroundAppHandoffService {
        ForegroundAppHandoffService(destinations: [:], opener: NeverOpener(), isAppActive: { active }, links: self.table, launcher: launcher, lookup: lookup)
    }

    private func payload(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(json) = result else { XCTFail("expected success, got \(result)"); return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testAKnownAppOpensByItsOwnLinkWithoutAskingApple() async throws {
        let launcher = RecordingLauncher(); let lookup = FixedLookup(nil)
        let result = await service(launcher, lookup: lookup).handleNodeCommand("apps.open", paramsJSON: #"{"name":"Google Docs"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(launcher.links, [URL(string: "googledocs://")!])
        XCTAssertEqual(launcher.bundles, [])
        let asked = await lookup.asked; XCTAssertEqual(asked, [])
        let body = try payload(result)
        XCTAssertEqual(body["opened"] as? Bool, true)
        XCTAssertEqual(body["destinationKind"] as? String, "app")
        XCTAssertEqual(body["actionCompleted"] as? Bool, false)
    }

    func testWhenTheLinkIsRefusedTheBundleIDIsTried() async throws {
        let launcher = RecordingLauncher(); launcher.linkOpens = false
        _ = try payload(await service(launcher).handleNodeCommand("apps.open", paramsJSON: #"{"name":"docs"}"#, timeoutMilliseconds: nil))
        XCTAssertEqual(launcher.bundles, ["com.google.Docs"])
    }

    func testAnAppNotInTheTableIsFoundByNameThenOpened() async throws {
        let launcher = RecordingLauncher(); let lookup = FixedLookup("com.example.birdwatch")
        _ = try payload(await service(launcher, lookup: lookup).handleNodeCommand("apps.open", paramsJSON: #"{"name":"  Birdwatch "}"#, timeoutMilliseconds: nil))
        let asked = await lookup.asked; XCTAssertEqual(asked, ["Birdwatch"])
        XCTAssertEqual(launcher.bundles, ["com.example.birdwatch"])
    }

    /// Seen in the real app: asked to open Settings, the model sent appID "settings".
    func testAnAppNameSentAsAppIDStillOpensTheApp() async throws {
        let launcher = RecordingLauncher()
        _ = try payload(await service(launcher).handleNodeCommand("apps.open", paramsJSON: #"{"appID":"camera"}"#, timeoutMilliseconds: nil))
        XCTAssertEqual(launcher.bundles, ["com.apple.camera"])
    }

    func testNothingOpensWhenTheAppCannotBeFoundOrWillNotLaunch() async {
        let missing = RecordingLauncher()
        let notFound = await service(missing).handleNodeCommand("apps.open", paramsJSON: #"{"name":"Nonexistent"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(notFound, .failure(code: "APP_NOT_FOUND", message: "No app with that name was found"))
        XCTAssertEqual(missing.bundles, [])

        let refused = RecordingLauncher(); refused.bundleOpens = false
        let failed = await service(refused).handleNodeCommand("apps.open", paramsJSON: #"{"name":"camera"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(failed, .failure(code: "OPEN_FAILED", message: "The app did not open; it may not be installed on this iPhone"))
    }

    func testBadShapesAndAnInactiveAppOpenNothing() async {
        for input in [#"{"name":"docs","appID":"example"}"#, #"{"name":""}"#, #"{"name":"a\nb"}"#, #"{"name":42}"#, #"{"name":"docs","url":"x://"}"#] {
            let launcher = RecordingLauncher()
            let result = await service(launcher).handleNodeCommand("apps.open", paramsJSON: input, timeoutMilliseconds: nil)
            guard case .failure(code: "INVALID_REQUEST", _) = result else { XCTFail(input); continue }
            XCTAssertEqual(launcher.links.count + launcher.bundles.count, 0, input)
        }
        let launcher = RecordingLauncher()
        let result = await service(launcher, active: false).handleNodeCommand("apps.open", paramsJSON: #"{"name":"docs"}"#, timeoutMilliseconds: nil)
        guard case .failure(code: "APP_NOT_ACTIVE", _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(launcher.links.count, 0)
    }

    func testTheBundledTableOnlyHoldsAppLinksAndBundleIDs() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Resources/connections/handoff/app-links.json").standardized
        let table = try AppLinkTable.decode(Data(contentsOf: file))
        XCTAssertGreaterThan(table.entries.count, 40)
        XCTAssertEqual(table.match("Google Docs")?.link, "googledocs://")
        XCTAssertEqual(table.match("settings")?.bundleID, "com.apple.Preferences")
    }

    func testAppleSearchPicksTheAppWithThatNameAndRefusesLookalikes() async throws {
        let body = #"{"resultCount":2,"results":[{"trackName":"Birdwatch Pro: Guide","bundleId":"com.other.pro"},{"trackName":"Birdwatch","bundleId":"com.example.birdwatch"}]}"#
        let seen = SeenURL()
        let lookup = AppStoreBundleLookup(region: "us") { request in
            await seen.set(request.url)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let found = await lookup.bundleID(forName: "birdwatch")
        XCTAssertEqual(found, "com.example.birdwatch")
        let asked = await seen.url
        XCTAssertEqual(asked?.host, "itunes.apple.com")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(asked), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value, "birdwatch")
        let none = await lookup.bundleID(forName: "Heron Counter")
        XCTAssertNil(none)
    }
}

@MainActor private final class RecordingLauncher: InstalledAppLaunching {
    var links: [URL] = []; var bundles: [String] = []
    var linkOpens = true; var bundleOpens = true
    func openLink(_ url: URL) async -> Bool { links.append(url); return linkOpens }
    func openBundle(_ bundleID: String) -> Bool { bundles.append(bundleID); return bundleOpens }
}

private actor FixedLookup: AppBundleLookup {
    private(set) var asked: [String] = []
    private let answer: String?
    init(_ answer: String?) { self.answer = answer }
    func bundleID(forName name: String) async -> String? { asked.append(name); return answer }
}

@MainActor private final class NeverOpener: AppHandoffOpener {
    func open(_ url: URL) async -> Bool { false }
}

private actor SeenURL { private(set) var url: URL?; func set(_ value: URL?) { url = value } }
