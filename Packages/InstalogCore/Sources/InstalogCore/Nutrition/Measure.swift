import Foundation

public enum MeasureDimension: String, Codable, Sendable {
    case mass
    case volume
    case serving
}

/// The quantity that a food's nutrient amounts refer to, e.g. per 100 g or per 1 bar.
public struct NutritionBasis: Hashable, Sendable, Codable {
    public var amount: Double
    public var dimension: MeasureDimension
    /// Name of one serving for serving-based foods ("bar", "scoop").
    public var servingName: String?
    /// Optional mass of one serving, enabling gram entry for serving-based foods.
    public var servingGrams: Double?
    /// Optional volume of one serving, enabling milliliter entry for serving-based foods.
    public var servingMilliliters: Double?

    public init(
        amount: Double, dimension: MeasureDimension, servingName: String? = nil, servingGrams: Double? = nil,
        servingMilliliters: Double? = nil
    ) {
        self.amount = amount
        self.dimension = dimension
        self.servingName = servingName
        self.servingGrams = servingGrams
        self.servingMilliliters = servingMilliliters
    }

    public static let per100Grams = NutritionBasis(amount: 100, dimension: .mass)
    public static let per100Milliliters = NutritionBasis(amount: 100, dimension: .volume)

    public var isValid: Bool {
        amount.isFinite && amount > 0
            && [servingGrams, servingMilliliters].allSatisfy { value in value.map { $0.isFinite && $0 > 0 } ?? true }
    }

    public var label: String {
        switch dimension {
        case .mass: "per \(NumberFormatting.quantity(amount)) g"
        case .volume: "per \(NumberFormatting.quantity(amount)) mL"
        case .serving: "per \(NumberFormatting.quantity(amount)) \(servingName ?? "serving")"
        }
    }
}

/// A food-specific household measure with a known mass or volume for one unit of it.
public struct FoodPortion: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var grams: Double?
    public var milliliters: Double?

    public init(id: String, name: String, grams: Double? = nil, milliliters: Double? = nil) {
        self.id = id
        self.name = name
        self.grams = grams
        self.milliliters = milliliters
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (grams != nil || milliliters != nil)
            && [grams, milliliters].allSatisfy { value in value.map { $0.isFinite && $0 > 0 } ?? true }
    }
}

public enum MeasureUnit: Hashable, Sendable, Codable {
    case gram
    case ounce
    case milliliter
    case fluidOunce
    /// One basis serving of a serving-based food.
    case serving
    case portion(id: String)

    public static let gramsPerOunce = 28.349_523_125
    public static let millilitersPerFluidOunce = 29.573_529_562_5
}

public enum MeasureError: Error, Equatable, Sendable {
    case invalidQuantity
    case unknownPortion(String)
    case unsupportedConversion(from: MeasureDimension, to: MeasureDimension)
}

/// Everything needed to turn a logged quantity into nutrient amounts. Saved on foods and copied
/// into each logged snapshot so history never depends on the current catalog record.
public struct FoodNutrition: Hashable, Sendable, Codable {
    public var basis: NutritionBasis
    public var nutrients: NutrientProfile
    public var portions: [FoodPortion]
    /// Grams per milliliter, only when the source documents a density.
    public var density: Double?

    public init(basis: NutritionBasis, nutrients: NutrientProfile, portions: [FoodPortion] = [], density: Double? = nil) {
        self.basis = basis
        self.nutrients = nutrients
        self.portions = portions
        self.density = density
    }

    public func portion(id: String) -> FoodPortion? { portions.first { $0.id == id } }

    /// Units that can be converted to this food's basis without guessing.
    public var supportedUnits: [MeasureUnit] {
        let candidates: [MeasureUnit] = [.serving, .gram, .ounce, .milliliter, .fluidOunce]
            + portions.map { .portion(id: $0.id) }
        return candidates.filter { (try? basisMultiple(quantity: 1, unit: $0)) != nil }
    }

    public func label(for unit: MeasureUnit, quantity: Double = 1) -> String {
        switch unit {
        case .gram: "g"
        case .ounce: "oz"
        case .milliliter: "mL"
        case .fluidOunce: "fl oz"
        case .serving: basis.servingName ?? (quantity == 1 ? "serving" : "servings")
        case .portion(let id): portion(id: id)?.name ?? "portion"
        }
    }

    /// The number of basis amounts represented by `quantity` of `unit`.
    public func basisMultiple(quantity: Double, unit: MeasureUnit) throws -> Double {
        guard quantity.isFinite, quantity >= 0 else { throw MeasureError.invalidQuantity }
        let (value, dimension) = try resolve(quantity: quantity, unit: unit)
        let inBasisDimension = try convert(value, from: dimension, to: basis.dimension)
        return inBasisDimension / basis.amount
    }

    public func nutrients(quantity: Double, unit: MeasureUnit) throws -> NutrientProfile {
        nutrients.scaled(by: try basisMultiple(quantity: quantity, unit: unit))
    }

    /// Grams represented by a quantity, when the food has the information to say.
    public func grams(quantity: Double, unit: MeasureUnit) -> Double? {
        guard let (value, dimension) = try? resolve(quantity: quantity, unit: unit) else { return nil }
        return try? convert(value, from: dimension, to: .mass)
    }

    private func resolve(quantity: Double, unit: MeasureUnit) throws -> (Double, MeasureDimension) {
        switch unit {
        case .gram: return (quantity, .mass)
        case .ounce: return (quantity * MeasureUnit.gramsPerOunce, .mass)
        case .milliliter: return (quantity, .volume)
        case .fluidOunce: return (quantity * MeasureUnit.millilitersPerFluidOunce, .volume)
        case .serving:
            guard basis.dimension == .serving else {
                throw MeasureError.unsupportedConversion(from: .serving, to: basis.dimension)
            }
            return (quantity, .serving)
        case .portion(let id):
            guard let portion = portion(id: id) else { throw MeasureError.unknownPortion(id) }
            if let grams = portion.grams { return (quantity * grams, .mass) }
            if let milliliters = portion.milliliters { return (quantity * milliliters, .volume) }
            throw MeasureError.unknownPortion(id)
        }
    }

    private func convert(_ value: Double, from: MeasureDimension, to: MeasureDimension) throws -> Double {
        switch (from, to) {
        case (.mass, .mass), (.volume, .volume), (.serving, .serving):
            return value
        case (.volume, .mass):
            if let density, density > 0 { return value * density }
        case (.mass, .volume):
            if let density, density > 0 { return value / density }
        case (.mass, .serving):
            if let grams = basis.servingGrams { return value / grams }
        case (.serving, .mass):
            if let grams = basis.servingGrams { return value * grams }
        case (.volume, .serving):
            if let milliliters = basis.servingMilliliters { return value / milliliters }
        case (.serving, .volume):
            if let milliliters = basis.servingMilliliters { return value * milliliters }
        }
        throw MeasureError.unsupportedConversion(from: from, to: to)
    }

    public var isValid: Bool {
        basis.isValid && nutrients.isValid && portions.allSatisfy(\.isValid)
            && (density.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

public extension FoodNutrition {
    /// The same amount of food expressed in another unit, rounded to two decimals and clamped to
    /// what can be entered. Nil when the units can't be converted for this food.
    func convert(quantity: Double, from: MeasureUnit, to: MeasureUnit) -> Double? {
        guard from != to else { return quantity }
        guard let source = try? basisMultiple(quantity: quantity, unit: from),
            let perTarget = try? basisMultiple(quantity: 1, unit: to), perTarget > 0
        else { return nil }
        return QuantityInput.clamp(((source / perTarget) * 100).rounded() / 100, unit: to)
    }
}
