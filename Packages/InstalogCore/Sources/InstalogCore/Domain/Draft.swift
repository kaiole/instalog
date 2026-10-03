import Foundation

/// One food in a composition being prepared for logging. Editing it never touches a template.
public struct DraftItem: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var food: FoodDefinition
    public var quantity: Double
    public var unit: MeasureUnit
    /// Default quantity from the saved meal, when the item came from one.
    public var templateQuantity: Double?

    public init(id: UUID = UUID(), food: FoodDefinition, quantity: Double, unit: MeasureUnit, templateQuantity: Double? = nil) {
        self.id = id
        self.food = food
        self.quantity = quantity
        self.unit = unit
        self.templateQuantity = templateQuantity
    }

    public var isAdjusted: Bool {
        guard let templateQuantity else { return false }
        return abs(templateQuantity - quantity) > 1e-9
    }

    public var calculatorItem: NutritionCalculator.Item {
        NutritionCalculator.Item(nutrition: food.nutrition, quantity: quantity, unit: unit)
    }

    public var unitLabel: String { food.nutrition.label(for: unit, quantity: quantity) }

    /// Items for a saved meal at its default quantities. Items whose food is missing are dropped.
    public static func items(for meal: MealTemplate, foods: [UUID: FoodDefinition]) -> [DraftItem] {
        meal.items.compactMap { item in
            guard let food = foods[item.foodID] else { return nil }
            return DraftItem(
                id: item.id, food: food, quantity: item.defaultQuantity, unit: item.unit,
                templateQuantity: item.defaultQuantity)
        }
    }
}

public enum QuantityStep {
    /// Increment used by the − / + controls for a unit at a given amount.
    public static func step(for unit: MeasureUnit, quantity: Double) -> Double {
        switch unit {
        case .gram, .milliliter:
            if quantity < 20 { return 1 }
            if quantity < 100 { return 5 }
            if quantity < 500 { return 10 }
            return 25
        case .ounce, .fluidOunce: return 0.5
        case .serving, .portion: return quantity < 1 ? 0.25 : 0.5
        }
    }

    public static func increase(_ quantity: Double, unit: MeasureUnit) -> Double {
        let step = step(for: unit, quantity: quantity)
        return QuantityInput.clamp(((quantity + step) / step).rounded(.down) * step, unit: unit)
    }

    public static func decrease(_ quantity: Double, unit: MeasureUnit) -> Double {
        guard quantity > 0 else { return 0 }
        let justBelow = quantity - 1e-9
        let step = step(for: unit, quantity: justBelow)
        return max(0, (justBelow / step).rounded(.down) * step)
    }
}
