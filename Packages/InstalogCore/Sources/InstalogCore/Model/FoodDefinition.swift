import Foundation

public enum FoodSource: String, Codable, Sendable {
    case usda
    case custom
}

/// A generic, branded or user-created food stored on the device.
public struct FoodDefinition: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var source: FoodSource
    /// USDA FDC ID for catalog foods.
    public var sourceFoodID: String?
    public var name: String
    public var brand: String?
    public var preparation: String?
    public var category: String?
    /// Dataset within the source, e.g. "SR Legacy".
    public var sourceDataType: String?
    public var sourceVersion: String?
    public var retrievedAt: Date?
    public var nutrition: FoodNutrition
    /// USDA derivation descriptions keyed by nutrient, when the source supplies them.
    public var derivations: [NutrientID: String]
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when a custom food is deleted. Archived foods are hidden from search but kept so
    /// saved meals and exports that reference them stay valid.
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(), source: FoodSource, sourceFoodID: String? = nil, name: String, brand: String? = nil,
        preparation: String? = nil, category: String? = nil, sourceDataType: String? = nil,
        sourceVersion: String? = nil, retrievedAt: Date? = nil, nutrition: FoodNutrition,
        derivations: [NutrientID: String] = [:], createdAt: Date = Date(), updatedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceFoodID = sourceFoodID
        self.name = name
        self.brand = brand
        self.preparation = preparation
        self.category = category
        self.sourceDataType = sourceDataType
        self.sourceVersion = sourceVersion
        self.retrievedAt = retrievedAt
        self.nutrition = nutrition
        self.derivations = derivations
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.archivedAt = archivedAt
    }

    public var isArchived: Bool { archivedAt != nil }

    /// Identity of the catalog record this food was copied from, if any.
    public var catalogKey: String? {
        guard source == .usda, let sourceFoodID else { return nil }
        return "usda:\(sourceDataType ?? ""):\(sourceVersion ?? ""):\(sourceFoodID)"
    }

    public var sourceLabel: String {
        switch source {
        case .usda: ["USDA", sourceDataType].compactMap { $0 }.joined(separator: " ")
        case .custom: "Custom"
        }
    }
}

public enum FoodValidationError: Error, Equatable, Sendable {
    case blankName
    case invalidBasis
    case noNutrients
    case invalidNutrientValue
    case invalidPortion
}

public extension FoodDefinition {
    static let maximumBasisAmount = 10_000.0
    static let maximumNutrientValue = 1_000_000.0

    /// Rules for user-created foods: a name, a positive basis, and at least one explicitly supplied
    /// finite, nonnegative nutrient value. Blank nutrients stay unknown.
    static func validateCustom(name: String, nutrition: FoodNutrition) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FoodValidationError.blankName }
        if !nutrition.basis.isValid || nutrition.basis.amount > maximumBasisAmount {
            throw FoodValidationError.invalidBasis
        }
        if nutrition.nutrients.isEmpty { throw FoodValidationError.noNutrients }
        if !nutrition.nutrients.isValid || nutrition.nutrients.values.values.contains(where: { $0 > maximumNutrientValue }) {
            throw FoodValidationError.invalidNutrientValue
        }
        if !nutrition.portions.allSatisfy(\.isValid) { throw FoodValidationError.invalidPortion }
        if let density = nutrition.density, !(density.isFinite && density > 0) {
            throw FoodValidationError.invalidPortion
        }
    }
}
