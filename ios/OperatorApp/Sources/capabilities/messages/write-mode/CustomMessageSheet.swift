import SwiftUI

/// The card that rises when Operator is about to text someone and the person
/// writes their own messages: who it is for, a place to write, Send.
struct CustomMessageSheet: View {
    let request: CustomMessagePrompt.Request
    @ObservedObject var prompt: CustomMessagePrompt

    @State private var words = ""
    @FocusState private var isWriting: Bool

    private var canSend: Bool { !self.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR MESSAGE")
                .font(OperatorLettering.font(.caption2, .medium))
                .kerning(1.3)
                .foregroundStyle(OperatorBrand.vermilion)
            Text("What do you want to say to \(self.request.recipients.formatted(.list(type: .and)))?")
                .font(OperatorLettering.font(.title3, .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Operator sends exactly what you write, with no second tap.")
                .font(OperatorLettering.font(.footnote))
                .foregroundStyle(OperatorBrand.muted)
            TextEditor(text: self.$words)
                .focused(self.$isWriting)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 96, maxHeight: 160)
                .background(OperatorBrand.fillStrong, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Your message")
                .accessibilityIdentifier("custom-message-text")
            Button { self.prompt.submit(self.words) } label: {
                Text("Send")
                    .font(OperatorLettering.font(.subheadline, .medium))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(OperatorBrand.nearBlack)
                    .background(OperatorBrand.vermilion.opacity(self.canSend ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!self.canSend)
            .accessibilityIdentifier("custom-message-send")
            Button { self.prompt.decline() } label: {
                Text("Don't send")
                    .font(OperatorLettering.font(.footnote))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(OperatorBrand.light.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("custom-message-decline")
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(OperatorBrand.light)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
        .presentationBackground {
            OperatorBrand.nearBlack.overlay(OperatorBrand.light.opacity(0.07))
        }
        // Swiping the card away is the same answer as Don't send.
        .onDisappear { self.prompt.decline() }
        .onAppear { self.isWriting = true }
    }
}
