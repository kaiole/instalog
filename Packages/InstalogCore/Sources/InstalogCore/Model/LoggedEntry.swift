import Foundation

public enum EntryPath: String, Codable, Sendable {
    /// Logged from the section's selected saved meal.
    case normal
    /// Logged through Add food.
    case additional
}

/// Immutable record of one food as it was logged, with enough data to edit the quantity and
/// recalculate nutrition without consulting any newer source record.
public struct LoggedFoodSnapshot: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var foodID: UUID?
    public var name: String
    public var brand: String?
    public var preparation: String?
    public var source: FoodSource
    public var sourceFoodID: String?
    public var sourceDataType: String?
    public var sourceVersion: String?
    public var quantity: Double
    public var unit: MeasureUnit
    public var nutrition: FoodNutrition
    /// Quantity from the originating template item, for showing what was adjusted.
    public var templateQuantity: Double?

    public init(
        id: UUID = UUID(), food: FoodDefinition, quantity: Double, unit: MeasureUnit, templateQuantity: Double? = nil
    ) {
        self.id = id
        self.foodID = food.id
        self.name = food.name
        self.brand = food.brand
        self.preparation = food.preparation
        self.source = food.source
        self.sourceFoodID = food.sourceFoodID
        self.sourceDataType = food.sourceDataType
        self.sourceVersion = food.sourceVersion
        self.quantity = quantity
        self.unit = unit
        self.nutrition = food.nutrition
        self.templateQuantity = templateQuantity
    }

    public var calculatorItem: NutritionCalculator.Item {
        NutritionCalculator.Item(nutrition: nutrition, quantity: quantity, unit: unit)
    }

    public var unitLabel: String { nutrition.label(for: unit, quantity: quantity) }

    /// Identity of the catalog record this food was copied from, matching `FoodDefinition.catalogKey`.
    public var catalogKey: String? {
        guard source == .usda, let sourceFoodID else { return nil }
        return "usda:\(sourceDataType ?? ""):\(sourceVersion ?? ""):\(sourceFoodID)"
    }

    /// A food definition carrying this snapshot's data, reusing the original food ID when known.
    public var asFoodDefinition: FoodDefinition {
        FoodDefinition(
            id: foodID ?? id, source: source, sourceFoodID: sourceFoodID, name: name, brand: brand,
            preparation: preparation, sourceDataType: sourceDataType, sourceVersion: sourceVersion,
            nutrition: nutrition)
    }
}

/// A historical record of something the user logged on a particular day.
public struct LoggedEntry: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var logDate: LogDate
    /// When the entry was recorded; determines order within a section.
    public var recordedAt: Date
    public var updatedAt: Date
    public var sectionID: UUID?
    /// Section name at logging time, so history stays identifiable after renames or removal.
    public var sectionName: String?
    public var mealTemplateID: UUID?
    public var name: String
    public var path: EntryPath
    public var foods: [LoggedFoodSnapshot]

    public init(
        id: UUID = UUID(), logDate: LogDate, recordedAt: Date, sectionID: UUID?, sectionName: String?,
        mealTemplateID: UUID?, name: String, path: EntryPath, foods: [LoggedFoodSnapshot], updatedAt: Date? = nil
    ) {
        self.id = id
        self.logDate = logDate
        self.recordedAt = recordedAt
        self.updatedAt = updatedAt ?? recordedAt
        self.sectionID = sectionID
        self.sectionName = sectionName
        self.mealTemplateID = mealTemplateID
        self.name = name
        self.path = path
        self.foods = foods
    }

    public var isOneOff: Bool { mealTemplateID == nil }

    /// True when any quantity differs from the template it came from.
    public var isAdjusted: Bool {
        guard mealTemplateID != nil else { return false }
        return foods.contains { food in
            guard let templateQuantity = food.templateQuantity else { return true }
            return abs(templateQuantity - food.quantity) > 1e-9
        }
    }
}

public enum EntryValidationError: Error, Equatable, Sendable {
    case noFoods
    case invalidQuantity
    case unsupportedUnit
    case invalidNutrients
    case blankName
}

public extension LoggedEntry {
    func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw EntryValidationError.blankName }
        if foods.isEmpty { throw EntryValidationError.noFoods }
        for food in foods {
            guard food.quantity.isFinite, food.quantity > 0 else { throw EntryValidationError.invalidQuantity }
            guard food.nutrition.nutrients.isValid, food.nutrition.basis.isValid else {
                throw EntryValidationError.invalidNutrients
            }
            guard (try? food.nutrition.basisMultiple(quantity: food.quantity, unit: food.unit)) != nil else {
                throw EntryValidationError.unsupportedUnit
            }
        }
    }
}
