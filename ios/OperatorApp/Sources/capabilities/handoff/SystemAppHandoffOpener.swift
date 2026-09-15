import Foundation
import OSLog
import SafariServices
import UIKit

@MainActor
final class SystemAppHandoffOpener: AppHandoffOpener {
    func open(_ url: URL) async -> Bool {
        guard AppHandoffCatalog.isSafeDestination(url),
              UIApplication.shared.applicationState == .active,
              let host = ForegroundPresentationHost.topmost()
        else { return false }
        // Keep the node connection alive while reporting the opened page.
        // Leaving Operator for the Safari app disconnects it before its result.
        let browser = SFSafariViewController.operatorBrowser(url: url)
        return await withCheckedContinuation { continuation in
            host.present(browser, animated: true) {
                continuation.resume(returning: host.presentedViewController === browser)
            }
        }
    }
}

/// Dismisses an in-app `SFSafariViewController` when the user taps "Done".
///
/// `SFSafariViewController` does not dismiss itself — the host app must
/// implement `safariViewControllerDidFinish` and call `dismiss`. This stateless
/// singleton is the delegate for every in-app browser Operator presents (the
/// controller keeps only a `weak` delegate, so a permanent shared instance is
/// what keeps "Done" working). Returning to chat needs no extra state: the chat
/// UI is simply uncovered once the modally-presented browser is dismissed.
@MainActor
final class SafariReturnDelegate: NSObject, @preconcurrency SFSafariViewControllerDelegate {
    static let shared = SafariReturnDelegate()

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.dismiss(animated: true)
    }
}

extension SFSafariViewController {
    /// The one way Operator builds an in-app browser. It wires the shared
    /// return delegate so tapping "Done" dismisses the browser and uncovers
    /// chat. Every opener must go through here — the delegate was once
    /// forgotten and "Done" became a dead button covering chat forever.
    @MainActor
    static func operatorBrowser(url: URL) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.delegate = SafariReturnDelegate.shared
        return browser
    }
}

extension ForegroundAppHandoffService {
    convenience init(bundle: Bundle = .main) {
        let logger = Logger(subsystem: "app.operator.ios", category: "app-handoff")
        let destinations: [String: URL]
        do {
            guard let file = bundle.url(forResource: "android-handoff-catalog", withExtension: "json") else {
                throw AppHandoffCatalog.InvalidCatalog.invalidDestination
            }
            destinations = try AppHandoffCatalog.decode(Data(contentsOf: file))
            logger.info("[app-handoff] loaded destination count=\(destinations.count)")
        } catch {
            // Missing or malformed packaging must not open arbitrary URLs.
            destinations = [:]
            logger.error("[app-handoff] catalog unavailable; app opening disabled errorType=\(String(reflecting: type(of: error)), privacy: .public)")
        }
        self.init(destinations: destinations, opener: SystemAppHandoffOpener(), isAppActive: {
            UIApplication.shared.applicationState == .active
        })
    }
}
