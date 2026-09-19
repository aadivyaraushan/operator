import SwiftUI

/// First-run step after Permissions: how to put the Operator widget on the
/// Home Screen. iOS only lets the person place a widget, so this shows the
/// steps and notices when it has been done.
struct WidgetSetupScreen: View {
    @ObservedObject var model: WidgetSetupModel

    private static let steps = [
        "Go to your Home Screen and hold a finger on an empty spot.",
        "Tap Edit at the top, then Add Widget.",
        "Search for Operator and tap Add Widget.",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    WidgetPreview()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    Text("Keep Operator one tap away")
                        .font(OperatorLettering.font(.title2, .bold))
                    Text("Add the Operator widget to your Home Screen. Tapping it opens your chat. iPhone does not let an app add a widget for you, so it takes three steps.")
                        .font(OperatorLettering.font(.subheadline))
                        .foregroundStyle(OperatorBrand.muted)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(OperatorLettering.font(.subheadline, .medium))
                                    .foregroundStyle(OperatorBrand.vermilion)
                                    .frame(width: 14, alignment: .leading)
                                Text(step)
                            }
                        }
                    }
                    self.status
                    Text("The same widget fits on the Lock Screen, and Control Center has an Open Operator button.")
                        .font(OperatorLettering.font(.footnote))
                        .foregroundStyle(OperatorBrand.dim)
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .background(OperatorBrand.nearBlack)
            .navigationTitle("Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OperatorBrand.nearBlack, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(self.model.isPlaced ? "Continue" : "Not now") { self.model.finish() }
                        .accessibilityIdentifier("widget-setup-done")
                }
            }
            .interactiveDismissDisabled()
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if self.model.isPlaced {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OperatorBrand.vermilion)
                    .keepsShape()
                Text("Widget added")
            } else {
                Circle()
                    .fill(OperatorBrand.dim)
                    .frame(width: 6, height: 6)
                    .keepsShape()
                Text("Not added yet. Come back here after adding it.")
                    .foregroundStyle(OperatorBrand.muted)
            }
        }
        .font(OperatorLettering.font(.subheadline, .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("widget-setup-status")
    }
}

/// What the small Home Screen widget looks like, drawn to match it.
private struct WidgetPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OperatorMark(state: .idle, side: 44)
                .keepsShape()
            Spacer(minLength: 0)
            Text("Open Operator")
                .font(OperatorLettering.font(.headline, .bold))
        }
        .padding(16)
        .frame(width: 150, height: 150, alignment: .leading)
        .background(OperatorBrand.nearBlack, in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(OperatorBrand.fillStrong, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
