import Foundation

public enum TargetSource: Hashable, Sendable, Codable {
    case user
    case referenceTable(name: String, version: String)
}

/// A user-set goal, limit or reference for one nutrient, effective from a date onward.
/// A disabled record hides any target or reference for that nutrient; it is not a target of zero.
public struct NutritionTarget: Hashable, Sendable, Codable, Identifiable {
    public static let maximumAmount = 1_000_000.0

    public var id: UUID
    public var nutrientID: NutrientID
    public var kind: TargetKind
    public var amount: Double
    public var unit: NutrientUnit
    public var form: String?
    public var effectiveDate: LogDate
    public var enabled: Bool
    public var source: TargetSource

    public init(
        id: UUID = UUID(), nutrientID: NutrientID, kind: TargetKind, amount: Double, unit: NutrientUnit,
        form: String? = nil, effectiveDate: LogDate, enabled: Bool = true, source: TargetSource = .user
    ) {
        self.id = id
        self.nutrientID = nutrientID
        self.kind = kind
        self.amount = amount
        self.unit = unit
        self.form = form
        self.effectiveDate = effectiveDate
        self.enabled = enabled
        self.source = source
    }

    public var isValid: Bool { amount.isFinite && amount >= 0 }
}
