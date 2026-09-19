import SwiftUI

/// Brand lettering: Montserrat, narrowed to 94% of its width.
/// Medium for buttons and labels, Bold for headlines, Regular for body text.
enum OperatorLettering {
    static let widthScale: CGFloat = 0.94

    enum Weight: String {
        case regular = "Montserrat-Regular"
        case medium = "Montserrat-Medium"
        case bold = "Montserrat-Bold"
    }

    static func font(_ style: Font.TextStyle, _ weight: Weight = .regular) -> Font {
        .custom(weight.rawValue, size: self.pointSize(style), relativeTo: style)
    }

    /// The system's default size for each text style, so Dynamic Type scales
    /// Montserrat the way it scales the system font.
    static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    /// The width to offer content that will be drawn narrowed into `width`.
    static func widthToOffer(for width: CGFloat?) -> CGFloat? {
        width.map { $0 / self.widthScale }
    }

    /// The width narrowed content takes up once drawn.
    static func widthTaken(by contentWidth: CGFloat) -> CGFloat {
        contentWidth * self.widthScale
    }
}

/// Lays its content out wider than the space it has, so that once the content
/// is drawn narrowed it fills that space exactly and wraps where it should.
private struct NarrowedLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(self.offer(proposal))
        return CGSize(width: OperatorLettering.widthTaken(by: size.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: self.offer(ProposedViewSize(width: bounds.width, height: bounds.height)))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: OperatorLettering.widthToOffer(for: proposal.width), height: proposal.height)
    }
}

extension View {
    /// Draws everything inside at 94% width. Wrap a whole screen in it, and
    /// mark the logo and other round shapes with `keepsShape()`.
    func narrowedLettering() -> some View {
        NarrowedLayout {
            self.scaleEffect(x: OperatorLettering.widthScale, y: 1, anchor: .topLeading)
        }
    }

    /// Undoes the narrowing for a symbol: the brand doc narrows lettering only.
    func keepsShape() -> some View {
        self.scaleEffect(x: 1 / OperatorLettering.widthScale, y: 1)
    }
}
