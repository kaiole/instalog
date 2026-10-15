import Foundation

/// A repeatable sample routine built from real USDA SR Legacy records, for demos and testing.
public enum DemoRoutine {
    public struct Output: Sendable {
        public var foods: [FoodDefinition]
        public var meals: [MealTemplate]
        public var sections: [RoutineSection]
        public var targets: [NutritionTarget]
    }

    private enum Amount {
        case grams(Double)
        /// Quantity of the first portion whose name starts with the prefix.
        case portion(Double, String)
    }

    private struct Ingredient {
        let fdcID: String
        let amount: Amount
    }

    private static let mealSpecs: [(key: String, name: String, items: [Ingredient])] = [
        ("oats", "Overnight oats", [
            Ingredient(fdcID: "173904", amount: .grams(50)),
            Ingredient(fdcID: "171265", amount: .portion(1, "cup")),
            Ingredient(fdcID: "171711", amount: .grams(80)),
            Ingredient(fdcID: "170554", amount: .grams(10)),
        ]),
        ("yogurt", "Greek yogurt bowl", [
            Ingredient(fdcID: "170903", amount: .grams(200)),
            Ingredient(fdcID: "171646", amount: .grams(30)),
            Ingredient(fdcID: "167762", amount: .grams(80)),
            Ingredient(fdcID: "169640", amount: .portion(0.5, "tbsp")),
        ]),
        ("eggs", "Eggs & toast", [
            Ingredient(fdcID: "173423", amount: .portion(2, "large")),
            Ingredient(fdcID: "172688", amount: .portion(1, "slice")),
            Ingredient(fdcID: "171705", amount: .grams(50)),
            Ingredient(fdcID: "173410", amount: .grams(5)),
        ]),
        ("bowl", "Chicken rice bowl", [
            Ingredient(fdcID: "171477", amount: .grams(150)),
            Ingredient(fdcID: "168878", amount: .grams(180)),
            Ingredient(fdcID: "169967", amount: .grams(100)),
            Ingredient(fdcID: "171413", amount: .grams(10)),
            Ingredient(fdcID: "174277", amount: .portion(1, "tbsp")),
        ]),
        ("sandwich", "Turkey sandwich", [
            Ingredient(fdcID: "172688", amount: .portion(2, "slice")),
            Ingredient(fdcID: "172941", amount: .grams(90)),
            Ingredient(fdcID: "170899", amount: .grams(20)),
            Ingredient(fdcID: "169247", amount: .grams(20)),
            Ingredient(fdcID: "170457", amount: .grams(40)),
        ]),
        ("shake", "Protein shake", [
            Ingredient(fdcID: "173177", amount: .portion(1, "scoop")),
            Ingredient(fdcID: "173944", amount: .portion(1, "medium")),
            Ingredient(fdcID: "171265", amount: .portion(1, "cup")),
        ]),
        ("applepb", "Apple & peanut butter", [
            Ingredient(fdcID: "171688", amount: .portion(1, "medium")),
            Ingredient(fdcID: "172470", amount: .portion(2, "tbsp")),
        ]),
        ("salmon", "Salmon & potatoes", [
            Ingredient(fdcID: "175168", amount: .grams(140)),
            Ingredient(fdcID: "170440", amount: .grams(200)),
            Ingredient(fdcID: "169141", amount: .grams(100)),
            Ingredient(fdcID: "171413", amount: .grams(10)),
        ]),
    ]

    private static let sectionSpecs: [(name: String, meals: [String])] = [
        ("Breakfast", ["oats", "yogurt", "eggs"]),
        ("Lunch", ["bowl", "sandwich"]),
        ("Snack", ["shake", "applepb"]),
        ("Dinner", []),
    ]

    public static func build(catalog: any FoodCatalog, now: Date, startingSortOrder: Int = 0) async throws -> Output {
        var foodsByFDC: [String: FoodDefinition] = [:]
        for fdcID in Set(mealSpecs.flatMap { $0.items.map(\.fdcID) }) {
            if var food = try await catalog.food(id: fdcID) {
                food.createdAt = now
                food.updatedAt = now
                foodsByFDC[fdcID] = food
            }
        }

        var mealIDs: [String: UUID] = [:]
        var meals: [MealTemplate] = []
        for (offset, spec) in mealSpecs.enumerated() {
            let items: [MealTemplateItem] = spec.items.compactMap { ingredient in
                guard let food = foodsByFDC[ingredient.fdcID] else { return nil }
                switch ingredient.amount {
                case .grams(let grams):
                    return MealTemplateItem(foodID: food.id, defaultQuantity: grams, unit: .gram)
                case .portion(let quantity, let prefix):
                    guard let portion = food.nutrition.portions.first(where: { $0.name.hasPrefix(prefix) }) else {
                        return nil
                    }
                    return MealTemplateItem(foodID: food.id, defaultQuantity: quantity, unit: .portion(id: portion.id))
                }
            }
            guard !items.isEmpty else { continue }
            let meal = MealTemplate(
                name: spec.name, items: items, sortOrder: startingSortOrder + offset,
                createdAt: now.addingTimeInterval(Double(offset) / 1000))
            mealIDs[spec.key] = meal.id
            meals.append(meal)
        }

        let sections = sectionSpecs.enumerated().map { offset, spec in
            RoutineSection(name: spec.name, sortOrder: offset, mealIDs: spec.meals.compactMap { mealIDs[$0] }, createdAt: now)
        }

        let targets = [
            (NutrientID.energy, 2200.0), (.protein, 150), (.carbohydrate, 238), (.fat, 72),
        ].compactMap { id, amount -> NutritionTarget? in
            guard let definition = NutrientRegistry.definition(for: id) else { return nil }
            return NutritionTarget(
                nutrientID: id, kind: .target, amount: amount, unit: definition.unit, effectiveDate: .beginning)
        }

        return Output(foods: Array(foodsByFDC.values), meals: meals, sections: sections, targets: targets)
    }
}
