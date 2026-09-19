import SwiftUI

/// The four colors the brand doc allows, and the tints of them the app uses.
enum OperatorBrand {
    typealias RGB = (red: Int, green: Int, blue: Int)

    static let vermilionRGB: RGB = (0xFF, 0x59, 0x34)
    static let rustRGB: RGB = (0x9E, 0x39, 0x24)
    static let nearBlackRGB: RGB = (0x0B, 0x0B, 0x0B)
    static let lightRGB: RGB = (0xE8, 0xE6, 0xE2)

    /// Primary accent: actions, done marks, anything that needs the person.
    static let vermilion = color(vermilionRGB)
    /// Secondary accent: failures and the small disc of the mark.
    static let rust = color(rustRGB)
    /// Background.
    static let nearBlack = color(nearBlackRGB)
    /// Text and light surfaces.
    static let light = color(lightRGB)

    /// Quieter text: the light color, thinned.
    static let muted = light.opacity(0.66)
    static let dim = light.opacity(0.37)
    /// Raised surfaces: the light color laid thinly over the background.
    static let fill = light.opacity(0.05)
    static let fillStrong = light.opacity(0.08)

    static func hex(_ rgb: RGB) -> String {
        String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    private static func color(_ rgb: RGB) -> Color {
        Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

/// The filled action button: vermilion with near-black lettering.
struct OperatorPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OperatorLettering.font(.subheadline, .medium))
            .foregroundStyle(OperatorBrand.nearBlack)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(OperatorBrand.vermilion, in: Capsule())
            .opacity(self.isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}

/// The quiet button beside it: light lettering on a thin fill.
struct OperatorQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OperatorLettering.font(.subheadline, .medium))
            .foregroundStyle(OperatorBrand.light)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? OperatorBrand.fill : OperatorBrand.fillStrong, in: Capsule())
            .opacity(self.isEnabled ? 1 : 0.35)
    }
}
