import Foundation

/// Presentation rounding. Calculations never round; only these display helpers do.
/// Never traps: non-finite values show as "—".
public enum NumberFormatting {
    public static let unknown = "—"

    // Single-argument forms, usable as function references (`.map(NumberFormatting.energy)`).
    public static func quantity(_ value: Double) -> String { quantity(value, locale: .current) }
    public static func energy(_ value: Double) -> String { energy(value, locale: .current) }
    public static func nutrient(_ value: Double) -> String { nutrient(value, locale: .current) }
    public static func percent(_ fraction: Double) -> String? { percent(fraction, locale: .current) }

    public static func quantity(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return unknown }
        return (value + 0).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    public static func energy(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return unknown }
        return (value.rounded() + 0).formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    /// Nutrient amounts: whole numbers at 10 and above, otherwise up to two significant decimals.
    public static func nutrient(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return unknown }
        let magnitude = abs(value)
        if magnitude >= 10 {
            return (value.rounded() + 0).formatted(.number.precision(.fractionLength(0)).locale(locale))
        }
        if magnitude >= 1 { return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) }
        if value == 0 { return "0" }
        return value.formatted(.number.precision(.significantDigits(1...2)).locale(locale))
    }

    public static func nutrient(_ value: Double, unit: NutrientUnit) -> String {
        unit == .kilocalorie ? "\(energy(value)) kcal" : "\(nutrient(value)) \(unit.rawValue)"
    }

    /// Whole percent for a fraction (0.5 → "50%"), or nil when it can't be shown.
    public static func percent(_ fraction: Double, locale: Locale) -> String? {
        guard fraction.isFinite else { return nil }
        return ((fraction * 100).rounded() + 0).formatted(.number.precision(.fractionLength(0)).locale(locale)) + "%"
    }
}
