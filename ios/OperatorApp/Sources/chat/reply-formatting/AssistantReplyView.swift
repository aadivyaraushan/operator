import SwiftUI
import UIKit

/// An Operator reply: prose with formulas in the line, code in its own card,
/// and stand-alone formulas on their own row.
struct AssistantReplyView: View {
    let text: String

    @ScaledMetric(relativeTo: .body) private var formulaSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ReplyBlocks.parse(self.text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .prose(line):
                    self.prose(line)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                case let .code(language, code):
                    CodeBlockCard(language: language, code: code)
                case let .math(latex):
                    self.displayFormula(latex)
                }
            }
        }
    }

    private func prose(_ line: [ReplyInline]) -> Text {
        line.reduce(Text(verbatim: "")) { soFar, piece in
            switch piece {
            case let .text(text):
                return Text("\(soFar)\(Text(ChatMessageText.assistantText(text)))")
            case let .math(latex):
                guard let formula = FormulaImage.render(latex, mode: .inline, fontSize: self.formulaSize) else {
                    return Text("\(soFar)\(Text(verbatim: latex).font(.system(.body, design: .monospaced)))")
                }
                let picture = Text(Image(uiImage: formula.image))
                    .baselineOffset(-formula.descent)
                    .accessibilityLabel(latex)
                return Text("\(soFar)\(picture)")
            }
        }
    }

    @ViewBuilder
    private func displayFormula(_ latex: String) -> some View {
        if let formula = FormulaImage.render(latex, mode: .display, fontSize: self.formulaSize + 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: formula.image)
                    .accessibilityLabel(latex)
            }
            .padding(.vertical, 4)
        } else {
            CodeBlockCard(language: nil, code: latex)
        }
    }
}

/// A fenced block from a reply: monospaced, scrolls sideways instead of
/// wrapping, with the language and a copy button above it.
private struct CodeBlockCard: View {
    let language: String?
    let code: String

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.language ?? "code")
                    .font(OperatorLettering.font(.caption, .medium))
                    .foregroundStyle(OperatorBrand.muted)
                Spacer()
                Button(action: self.copy) {
                    Label(self.justCopied ? "Copied" : "Copy", systemImage: self.justCopied ? "checkmark" : "doc.on.doc")
                        .font(OperatorLettering.font(.caption, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.justCopied ? OperatorBrand.vermilion : OperatorBrand.muted)
                .accessibilityLabel(self.justCopied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OperatorBrand.fill)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: self.code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OperatorBrand.fillStrong, lineWidth: 1))
    }

    private func copy() {
        UIPasteboard.general.string = self.code
        self.justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.justCopied = false
        }
    }
}
