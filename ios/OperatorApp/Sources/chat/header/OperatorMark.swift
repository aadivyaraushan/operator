import SwiftUI

/// What the header logo is saying.
enum OperatorMarkState: Equatable {
    /// Nothing happening: the mark breathes slowly.
    case idle
    /// A run is in progress: the small disc circles the large one.
    case working
    /// Operator has stopped for the person: each disc sends out its own ring,
    /// the small one answering the large one.
    case waiting

    init(isWorking: Bool, needsPerson: Bool) {
        self = needsPerson ? .waiting : isWorking ? .working : .idle
    }
}

/// The brand mark: a large vermilion disc with a smaller rust disc below-left.
struct OperatorMark: View {
    let state: OperatorMarkState
    var side: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let vermilion = OperatorBrand.vermilion
    static let rust = OperatorBrand.rust

    private static let waitingPeriod = 1.4
    private static let smallDiscDelay = 0.35

    var body: some View {
        TimelineView(.animation(paused: self.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                self.disc(
                    color: Self.vermilion, diameter: self.side * 0.69,
                    offset: CGSize(width: self.side * 0.155, height: -self.side * 0.155),
                    pulse: self.pulse(at: t, delay: 0), swell: 0.08, reach: 7)
                self.disc(
                    color: Self.rust, diameter: self.side * 0.35,
                    offset: CGSize(width: -self.side * 0.325, height: self.side * 0.325),
                    pulse: self.pulse(at: t, delay: Self.smallDiscDelay), swell: 0.14, reach: 5)
            }
            .frame(width: self.side, height: self.side)
            .scaleEffect(self.breath(at: t))
            .rotationEffect(self.orbit(at: t))
        }
        .accessibilityHidden(true)
    }

    private func disc(color: Color, diameter: CGFloat, offset: CGSize, pulse: Double?, swell: CGFloat, reach: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .scaleEffect(1 + swell * Self.swellCurve(pulse))
            .background {
                if let pulse {
                    let spread = reach * 2 * CGFloat(min(pulse / 0.6, 1))
                    Circle()
                        .stroke(color.opacity(0.6 * max(0, 1 - pulse / 0.6)), lineWidth: 1.5)
                        .frame(width: diameter + spread, height: diameter + spread)
                }
            }
            .offset(offset)
    }

    /// Progress 0..<1 through one pulse, or nil when not waiting.
    private func pulse(at t: TimeInterval, delay: Double) -> Double? {
        guard self.state == .waiting, !self.reduceMotion else { return nil }
        let shifted = (t - delay).truncatingRemainder(dividingBy: Self.waitingPeriod)
        return (shifted < 0 ? shifted + Self.waitingPeriod : shifted) / Self.waitingPeriod
    }

    /// Up to full by 18% of the pulse, back to rest by 60%.
    private static func swellCurve(_ pulse: Double?) -> CGFloat {
        guard let pulse else { return 0 }
        if pulse < 0.18 { return CGFloat(pulse / 0.18) }
        if pulse < 0.6 { return CGFloat(1 - (pulse - 0.18) / 0.42) }
        return 0
    }

    private func breath(at t: TimeInterval) -> CGFloat {
        guard self.state == .idle, !self.reduceMotion else { return 1 }
        return CGFloat(1 + 0.03 * (1 - cos(2 * Double.pi * t / 3.4)))
    }

    private func orbit(at t: TimeInterval) -> Angle {
        guard self.state == .working, !self.reduceMotion else { return .zero }
        return .degrees(360 * (t / 1.4).truncatingRemainder(dividingBy: 1))
    }
}
