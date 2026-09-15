import OSLog
import UIKit

/// Where a system sheet raised by a node command is presented from.
///
/// Five presenters used to carry their own copy of this lookup, in two
/// flavours. Three required the root controller to be presenting nothing and
/// refused otherwise; on a physical iPhone 17 running iOS 26 that refusal
/// fired for `sms.compose` with the app active and nothing visibly presented,
/// so the message composer never appeared. The other two walked to the
/// topmost presented controller, which is what UIKit expects a presenter to
/// do and is the behaviour every caller now shares.
@MainActor
enum ForegroundPresentationHost {
    private static let logger = Logger(subsystem: "app.operator.ios", category: "presentation-host")

    /// The topmost view controller in the foreground-active scene, or nil with
    /// a log line naming which step found nothing.
    static func topmost(in application: UIApplication = .shared) -> UIViewController? {
        let scenes = application.connectedScenes.compactMap { $0 as? UIWindowScene }
        // On iOS 26 a physical iPhone answered applicationState == .active while
        // no scene reported .foregroundActive, so the composer never appeared.
        // The app being active is checked by every caller first; a foreground
        // scene that is merely inactive can still present.
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first(where: { !$0.windows.isEmpty })
        else {
            // A UIApplication with no delegate is not the one UIKit is running;
            // see SystemMessageComposer for how that happened once.
            let states = scenes.map { String(describing: $0.activationState.rawValue) }.joined(separator: ",")
            logger.info("[presentation-host] no usable window scene count=\(scenes.count) states=\(states, privacy: .public) appState=\(application.applicationState.rawValue) hasDelegate=\(application.delegate != nil)")
            return nil
        }
        guard let window = scene.keyWindow ?? scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            logger.info("[presentation-host] scene has no window")
            return nil
        }
        guard var controller = window.rootViewController else {
            logger.info("[presentation-host] key window has no root view controller keyWindow=\(window.isKeyWindow)")
            return nil
        }
        var depth = 0
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
            depth += 1
        }
        logger.info("[presentation-host] resolved depth=\(depth) keyWindow=\(window.isKeyWindow) sceneState=\(scene.activationState.rawValue) scenes=\(scenes.count)")
        return controller
    }
}
