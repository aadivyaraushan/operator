import AppIntents
import SwiftUI
import WidgetKit

// One tap into Operator from outside the app. Three surfaces, one behaviour:
// the Lock Screen widget (above the clock or beside it), the Home Screen
// widget, and the iOS 18 Control that can sit on the Lock Screen's two bottom
// buttons, in Control Center, or on the Action button. None of them show
// data; the widget's default tap opens the app and the Control opens it
// through an intent.

struct OperatorWidgetEntry: TimelineEntry {
    let date: Date
}

struct OperatorWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> OperatorWidgetEntry {
        OperatorWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (OperatorWidgetEntry) -> Void) {
        completion(OperatorWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OperatorWidgetEntry>) -> Void) {
        completion(Timeline(entries: [OperatorWidgetEntry(date: .now)], policy: .never))
    }
}

/// The brand symbol: a large disc with a smaller one below-left. Colours follow
/// the brand guidelines on the Home Screen; on the Lock Screen the system
/// renders widgets in one tint, so the large disc is marked accentable and the
/// small one stays dimmer.
struct OperatorMark: View {
    static let vermilion = Color(red: 1.0, green: 0x59 / 255, blue: 0x34 / 255)
    static let rust = Color(red: 0x9E / 255, green: 0x39 / 255, blue: 0x24 / 255)

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .fill(Self.vermilion)
                    .frame(width: side * 0.68, height: side * 0.68)
                    .offset(x: side * 0.12, y: -side * 0.12)
                    .widgetAccentable()
                Circle()
                    .fill(Self.rust)
                    .frame(width: side * 0.34, height: side * 0.34)
                    .offset(x: -side * 0.26, y: side * 0.26)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct OperatorWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch self.family {
        case .accessoryCircular:
            OperatorMark()
                .padding(4)
                .accessibilityLabel("Open Operator")
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                OperatorMark().frame(width: 26, height: 26)
                Text("Open Operator")
                    .font(.headline)
            }
            .containerBackground(for: .widget) { Color.clear }
        default:
            VStack(alignment: .leading, spacing: 10) {
                OperatorMark().frame(width: 44, height: 44)
                Spacer(minLength: 0)
                Text("Open Operator")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0xE8 / 255, green: 0xE6 / 255, blue: 0xE2 / 255))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0B / 255)
            }
        }
    }
}

struct OperatorWidget: Widget {
    let kind = "OperatorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: self.kind, provider: OperatorWidgetProvider()) { _ in
            OperatorWidgetView()
        }
        .configurationDisplayName("Operator")
        .description("Open your Operator chat.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

/// Runs when the Control is pressed. `openAppWhenRun` hands the tap to the
/// containing app; nothing else happens here.
struct OpenOperatorIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Operator"
    static let description = IntentDescription("Opens the Operator chat.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// The Control users can put on the Action button, the Lock Screen's bottom
/// corners, or Control Center. Controls only accept SF Symbols for their icon.
struct OpenOperatorControl: ControlWidget {
    static let kind = "OperatorControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenOperatorIntent()) {
                Label("Operator", systemImage: "circle.circle.fill")
            }
        }
        .displayName("Open Operator")
        .description("Opens Operator. Put it on the Action button or a Lock Screen button.")
    }
}

@main
struct OperatorWidgetBundle: WidgetBundle {
    var body: some Widget {
        OperatorWidget()
        OpenOperatorControl()
    }
}
