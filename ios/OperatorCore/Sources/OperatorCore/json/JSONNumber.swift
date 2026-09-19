import Foundation

/// Reading numbers out of JSON without mistaking them for booleans.
///
/// JSONSerialization bridges `0` and `1` to an NSNumber that satisfies
/// `is Bool`. So the obvious guard against `{"limit": true}` —
/// `guard let n = raw as? NSNumber, !(raw is Bool)` — also rejects `{"limit": 1}`
/// and `{"limit": 0}`, which is how a limit of exactly one came to be refused
/// by two shipped connectors before a test caught it.
///
/// `objCType` is the only reliable discriminator, and it is what
/// ForegroundAccountReadService already used. This is that idiom, in one place,
/// so the next caller inherits it rather than rediscovering the trap.
public enum JSONNumber {
    /// Whether a JSON value is genuinely a boolean, as opposed to a number
    /// that merely bridges like one.
    public static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return String(cString: number.objCType) == "c"
    }

    /// A whole number, or nil for a boolean, a non-number, or a fractional
    /// value such as 1.5.
    public static func integer(_ value: Any) -> Int? {
        guard !Self.isBoolean(value), let number = value as? NSNumber else { return nil }
        guard Double(number.intValue) == number.doubleValue else { return nil }
        return number.intValue
    }

    /// A finite double, or nil for a boolean, a non-number, or a value that
    /// is infinite or NaN.
    public static func double(_ value: Any) -> Double? {
        guard !Self.isBoolean(value), let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    /// A whole number inside a closed range, or nil.
    public static func integer(_ value: Any, in range: ClosedRange<Int>) -> Int? {
        guard let parsed = Self.integer(value), range.contains(parsed) else { return nil }
        return parsed
    }
}
