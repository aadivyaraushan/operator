import Foundation
import OSLog

#if canImport(UIKit)
import SafariServices
import UIKit
#endif

@MainActor
final class InAppMediaOpener: AppHandoffOpener {
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let publicHost: @Sendable (String) async -> Bool
    private let present: @MainActor @Sendable (URL) async -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "media-open")

    init(
        isAppActive: @escaping @MainActor @Sendable () -> Bool,
        publicHost: @escaping @Sendable (String) async -> Bool,
        present: @escaping @MainActor @Sendable (URL) async -> Bool
    ) {
        self.isAppActive = isAppActive
        self.publicHost = publicHost
        self.present = present
    }

    func open(_ url: URL) async -> Bool {
        self.logger.info("[media-open] input url_bytes=\(url.absoluteString.utf8.count)")
        guard !Task.isCancelled,
              self.isAppActive(),
              PublicMediaURLPolicy.isStructurallySafe(url),
              let host = url.host,
              await self.publicHost(host),
              !Task.isCancelled,
              self.isAppActive()
        else {
            self.logger.error("[media-open] refused error_code=unsafe_or_inactive")
            return false
        }
        let opened = await self.present(url)
        self.logger.info("[media-open] output opened=\(opened) playback_verified=false")
        return opened
    }
}

#if canImport(UIKit)
extension InAppMediaOpener {
    convenience init(
        publicHost: @escaping @Sendable (String) async -> Bool = PublicMediaURLPolicy.hostResolvesOnlyToPublicAddresses
    ) {
        self.init(
            isAppActive: { UIApplication.shared.applicationState == .active },
            publicHost: publicHost,
            present: Self.presentInOperator
        )
    }

    private static func presentInOperator(_ url: URL) async -> Bool {
        guard UIApplication.shared.applicationState == .active,
              let host = ForegroundPresentationHost.topmost()
        else { return false }

        let browser = SFSafariViewController(url: url)
        return await withCheckedContinuation { continuation in
            host.present(browser, animated: true) {
                continuation.resume(returning: host.presentedViewController === browser)
            }
        }
    }
}
#endif
