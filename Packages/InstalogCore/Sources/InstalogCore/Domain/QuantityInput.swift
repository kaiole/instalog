import Foundation

/// Rules for amounts the user types: what can be entered, how it's parsed, and the round-trip
/// text shown while editing. Display-only rounding lives in `NumberFormatting`.
public enum QuantityInput {
    /// Largest amount accepted for a unit. Generous for real meals, small enough to stay sane.
    public static func maximum(for unit: MeasureUnit) -> Double {
        switch unit {
        case .gram, .milliliter: 10_000
        case .ounce, .fluidOunce: 350
        case .serving, .portion: 100
        }
    }

    /// Clamps to `0...maximum(for:)`. Non-finite values become 0.
    public static func clamp(_ value: Double, unit: MeasureUnit) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), maximum(for: unit))
    }

    /// True for text that is, or can become, a valid amount: up to six digits and two decimals.
    public static func isAcceptableEditing(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9]{0,6}([.,][0-9]{0,2})?/) != nil
    }

    /// Parses a typed amount. Needs at least one digit; accepts "." or "," as the decimal
    /// separator; rejects exponents, hex, grouping and infinities.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.wholeMatch(of: /[0-9]*([.,][0-9]*)?/) != nil, trimmed.contains(where: \.isNumber) else {
            return nil
        }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Editable text for an amount: plain digits, the locale's decimal separator, no grouping,
    /// at most two decimals. Always parses back with `parse`.
    public static func text(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        let separator = locale.decimalSeparator ?? "."
        return separator == "." ? text : text.replacingOccurrences(of: ".", with: separator)
    }

    public static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
}
