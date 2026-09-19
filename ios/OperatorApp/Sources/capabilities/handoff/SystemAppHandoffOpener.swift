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
        let links: AppLinkTable
        do {
            guard let file = bundle.url(forResource: "app-links", withExtension: "json") else { throw AppLinkTable.InvalidTable.invalidEntry }
            links = try AppLinkTable.decode(Data(contentsOf: file))
            logger.info("[app-handoff] loaded app link count=\(links.entries.count)")
        } catch {
            links = .empty
            logger.error("[app-handoff] app link table unavailable; apps open by lookup only")
        }
        let lookup = AppStoreBundleLookup(region: Locale.current.region?.identifier.lowercased() ?? "us") { request in
            try await URLSession.shared.data(for: request)
        }
        self.init(destinations: destinations, opener: SystemAppHandoffOpener(), isAppActive: {
            UIApplication.shared.applicationState == .active
        }, links: links, launcher: SystemInstalledAppLauncher(), lookup: lookup)
    }
}

@MainActor
final class SystemInstalledAppLauncher: InstalledAppLaunching {
    private let logger = Logger(subsystem: "app.operator.ios", category: "app-handoff")

    func openLink(_ url: URL) async -> Bool {
        guard AppLinkTable.isAppLink(url.absoluteString) else { return false }
        return await UIApplication.shared.open(url, options: [:])
    }

    /// Apple's private launch-by-bundle-id call; there is no public one.
    /// App Store review rejects it, so it must be removed before a store
    /// submission. The names are looked up at run time, and a missing class
    /// or method is a plain false.
    func openBundle(_ bundleID: String) -> Bool {
        guard AppLinkTable.isBundleID(bundleID),
              let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { self.logger.error("[app-handoff] private launcher unavailable branch=no-workspace"); return false }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selector), let method = workspace.method(for: selector) else {
            self.logger.error("[app-handoff] private launcher unavailable branch=no-method"); return false
        }
        typealias Launch = @convention(c) (NSObject, Selector, NSString) -> Bool
        return unsafeBitCast(method, to: Launch.self)(workspace, selector, bundleID as NSString)
    }
}
