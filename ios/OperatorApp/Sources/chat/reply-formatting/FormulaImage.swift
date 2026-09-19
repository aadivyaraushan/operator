import OSLog
import SwiftMath
import UIKit

/// A LaTeX formula drawn as a picture in the reply's text colour.
struct FormulaImage {
    let image: UIImage
    /// How far the picture hangs below the line of text it sits in.
    let descent: CGFloat

    enum Mode { case inline, display }

    /// Nil when SwiftMath cannot read the LaTeX; callers show the source instead.
    @MainActor
    static func render(_ latex: String, mode: Mode, fontSize: CGFloat) -> FormulaImage? {
        let key = "\(mode)|\(fontSize)|\(latex)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached.formula }

        var math = MathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: UIColor(OperatorBrand.light),
            labelMode: mode == .inline ? .text : .display,
            textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard let image, let layout else {
            Self.logger.info("[reply-formatting] formula not drawn mode=\(String(describing: mode)) length=\(latex.count) reason=\(error?.localizedDescription ?? "no image")")
            Self.cache.setObject(Cached(nil), forKey: key)
            return nil
        }
        let formula = FormulaImage(image: image, descent: layout.descent)
        Self.cache.setObject(Cached(formula), forKey: key)
        return formula
    }

    /// A streamed reply is drawn again on every update; this keeps each
    /// formula from being typeset more than once.
    @MainActor private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 200
        return cache
    }()

    private final class Cached {
        let formula: FormulaImage?
        init(_ formula: FormulaImage?) { self.formula = formula }
    }

    private static let logger = Logger(subsystem: "app.operator.ios", category: "reply-formatting")
}
