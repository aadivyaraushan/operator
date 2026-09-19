import Combine
import Foundation
import OSLog
import WidgetKit

/// Remembers that the first-run widget step has been shown and closed.
protocol WidgetSetupStore {
    func loadFinished() -> Bool
    func saveFinished()
}

struct UserDefaultsWidgetSetupStore: WidgetSetupStore {
    private let defaults: UserDefaults
    private let key = "app.operator.widgetSetup.finished"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadFinished() -> Bool { self.defaults.bool(forKey: self.key) }
    func saveFinished() { self.defaults.set(true, forKey: self.key) }
}

/// Whether an Operator widget sits on the Home Screen or Lock Screen.
protocol WidgetPlacementChecking: Sendable {
    func isOperatorWidgetPlaced() async -> Bool
}

/// Asks iOS which of the app's widgets the person has placed. iOS offers no
/// way to place one for them; this only reads what they did.
struct SystemWidgetPlacement: WidgetPlacementChecking {
    static let widgetKind = "OperatorWidget"

    func isOperatorWidgetPlaced() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let placed = (try? result.get())?.contains { $0.kind == Self.widgetKind } ?? false
                continuation.resume(returning: placed)
            }
        }
    }
}

/// The screens that cover the chat on first launch, in order.
enum FirstRunStep: Equatable {
    case permissions
    case widget

    init?(permissionsDone: Bool, widgetStepDue: Bool) {
        if !permissionsDone {
            self = .permissions
        } else if widgetStepDue {
            self = .widget
        } else {
            return nil
        }
    }
}

/// The first-run step that shows how to add the Home Screen widget. Shown once
/// per install, and not at all when a widget is already in place.
@MainActor
final class WidgetSetupModel: ObservableObject {
    @Published private(set) var isDue = false
    @Published private(set) var isPlaced = false

    private let store: any WidgetSetupStore
    private let placement: any WidgetPlacementChecking
    private var isFinished: Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "widget-setup")

    init(store: any WidgetSetupStore, placement: any WidgetPlacementChecking) {
        self.store = store
        self.placement = placement
        self.isFinished = store.loadFinished()
    }

    /// Run at launch and each time the app comes forward, so a widget added
    /// while the step is showing is noticed when the person returns.
    func refresh() async {
        guard !self.isFinished else { return }
        let placed = await self.placement.isOperatorWidgetPlaced()
        guard !self.isFinished else { return }
        self.isPlaced = placed
        if placed, !self.isDue {
            self.logger.info("[widget-setup] widget already placed, step skipped")
            self.close()
        } else {
            self.isDue = true
            self.logger.info("[widget-setup] step due placed=\(placed)")
        }
    }

    func finish() {
        guard !self.isFinished else { return }
        self.logger.info("[widget-setup] step closed by owner placed=\(self.isPlaced)")
        self.close()
    }

    private func close() {
        self.isFinished = true
        self.isDue = false
        self.store.saveFinished()
    }
}
