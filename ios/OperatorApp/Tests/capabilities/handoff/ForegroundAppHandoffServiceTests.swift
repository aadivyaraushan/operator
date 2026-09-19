import Foundation
import OperatorCore
import SafariServices
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundAppHandoffServiceTests: XCTestCase {
    func testRouterReachesHandoffWithoutRoutingOtherCommandsThere() async throws {
        let opener = RecordingAppOpener()
        let handoff = service(opener)
        let other = UnusedNodeHandler()
        let router = ForegroundNodeCommandRouter(location: other, calendar: other, messages: other, maps: other, handoff: handoff, whatsapp: other, whatsappCompose: other, accounts: other, accountWrite: other, notion: other)
        let result = await router.handleNodeCommand("apps.open", paramsJSON: #"{"appID":"example"}"#, timeoutMilliseconds: nil)
        guard case .success = result else { return XCTFail("Router did not reach handoff") }
        XCTAssertEqual(opener.urls.count, 1)
        XCTAssertEqual(other.calls, 0)
        _ = await router.handleNodeCommand("sms.send", paramsJSON: "{}", timeoutMilliseconds: nil)
        XCTAssertEqual(opener.urls.count, 1)
    }
    private func service(_ opener: RecordingAppOpener, active: Bool = true) -> ForegroundAppHandoffService {
        ForegroundAppHandoffService(destinations: ["example": URL(string: "https://example.com/")!], opener: opener, isAppActive: { active })
    }

    func testOpensOnlyCatalogURLAndDoesNotTransmitDraft() async throws {
        let opener = RecordingAppOpener()
        let result = await service(opener).handleNodeCommand("apps.open", paramsJSON: #"{"appID":"example","draft":"Private draft remains in chat"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(opener.urls, [URL(string: "https://example.com/")!])
        guard case .success(let json) = result else { return XCTFail("Expected opened result") }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["opened"] as? Bool, true)
        XCTAssertEqual(payload["actionCompleted"] as? Bool, false)
        XCTAssertEqual(payload["draftTransferred"] as? Bool, false)
        XCTAssertEqual(payload["destinationKind"] as? String, "website")
        XCTAssertFalse(json.contains("Private draft"))
    }

    func testRejectsUnknownAppsAndCallerSuppliedURLs() async {
        for input in [#"{"appID":"unknown"}"#, #"{"appID":"example","url":"https://evil.test"}"#, #"{"appID":"example","draft":42}"#, "[]", "{}"] {
            let opener = RecordingAppOpener()
            let result = await service(opener).handleNodeCommand("apps.open", paramsJSON: input, timeoutMilliseconds: nil)
            guard case .failure = result else { return XCTFail("Accepted invalid input") }
            XCTAssertTrue(opener.urls.isEmpty)
        }
    }

    func testInactiveAppDoesNotOpenAnything() async {
        let opener = RecordingAppOpener()
        let result = await service(opener, active: false).handleNodeCommand("apps.open", paramsJSON: #"{"appID":"example"}"#, timeoutMilliseconds: nil)
        guard case .failure(let code, _) = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(code, "APP_NOT_ACTIVE")
        XCTAssertTrue(opener.urls.isEmpty)
    }

    func testFailedOpenIsNeverReportedAsSuccess() async {
        let opener = RecordingAppOpener(); opener.opens = false
        let result = await service(opener).handleNodeCommand("apps.open", paramsJSON: #"{"appID":"example"}"#, timeoutMilliseconds: nil)
        guard case .failure(let code, _) = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(code, "OPEN_FAILED")
    }

    func testCatalogRejectsUnsafeOrDuplicateDestinations() throws {
        for json in [#"[{"id":"x","url":"file:///private/x"}]"#, #"[{"id":"x","url":"https://user:pass@example.com/"}]"#, #"[{"id":"x","url":"https://example.com/?send=yes"}]"#, #"[{"id":"x","url":"https://example.com/"},{"id":"x","url":"https://example.org/"}]"#] {
            XCTAssertThrowsError(try AppHandoffCatalog.decode(Data(json.utf8)))
        }
        XCTAssertEqual(try AppHandoffCatalog.decode(Data(#"[{"id":"example","url":"https://example.com/","displayName":"Example"}]"#.utf8)).count, 1)
    }

    // Regression guard for the "stuck on the website" bug: an in-app browser
    // built without a delegate makes "Done" a no-op, so the browser covers
    // chat forever. Both openers now build through `operatorBrowser(url:)`, so
    // asserting the factory always wires the shared return delegate guards
    // every caller at once. `safariViewControllerDidFinish` then dismisses.
    func testOperatorBrowserAlwaysWiresTheReturnDelegateSoDoneReturnsToChat() {
        let browser = SFSafariViewController.operatorBrowser(url: URL(string: "https://example.com/")!)
        XCTAssertTrue(browser.delegate === SafariReturnDelegate.shared)

        // And the delegate's contract is to dismiss on Done, not sit there.
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = host
        window.isHidden = false
        host.present(browser, animated: false)
        XCTAssertTrue(host.presentedViewController === browser)
        SafariReturnDelegate.shared.safariViewControllerDidFinish(browser)
        // dismiss(animated:true) resolves on the next run-loop turns; poll for it.
        let dismissed = expectation(description: "browser dismissed on Done")
        func poll() {
            if host.presentedViewController == nil { dismissed.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
        wait(for: [dismissed], timeout: 3)
    }
}

@MainActor
private final class RecordingAppOpener: AppHandoffOpener {
    var urls: [URL] = []
    var opens = true
    func open(_ url: URL) async -> Bool { urls.append(url); return opens }
}

@MainActor
private final class UnusedNodeHandler: GatewayNodeCommandHandler {
    var calls = 0
    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        calls += 1
        return .failure(code: "WRONG_ROUTE", message: "Wrong handler")
    }
}
