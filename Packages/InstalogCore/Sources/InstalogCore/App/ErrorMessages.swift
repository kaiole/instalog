import Foundation

// User-facing wording for every error the app can surface. Views show `localizedDescription`
// directly, so these must read as complete sentences without any debugging detail.

extension LoggingBusyError: LocalizedError {
    public var errorDescription: String? { "Still saving. Try again in a moment." }
}

extension SectionNameError: LocalizedError {
    public var errorDescription: String? { "Give the section a name." }
}

extension TargetValueError: LocalizedError {
    public var errorDescription: String? { "Enter an amount of zero or more." }
}

extension FoodInUseError: LocalizedError {
    public var errorDescription: String? {
        let names = mealNames.map { "“\($0)”" }.formatted(.list(type: .and))
        return "Used in \(names). Remove it from \(mealNames.count == 1 ? "that meal" : "those meals") first."
    }
}

extension EntryValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noFoods: "Add at least one food with an amount above zero."
        case .invalidQuantity: "Every food needs an amount above zero."
        case .unsupportedUnit: "One of the units can’t be converted for that food."
        case .invalidNutrients: "One of the foods has invalid nutrition data."
        case .blankName: "Give the entry a name."
        }
    }
}

extension FoodValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blankName: "Give the food a name."
        case .invalidBasis: "The amount must be above zero and at most 10,000."
        case .noNutrients: "Enter at least one nutrient value."
        case .invalidNutrientValue: "Nutrient values must be zero or more."
        case .invalidPortion: "Serving weight must be above zero."
        }
    }
}

extension MealValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blankName: "Give the meal a name."
        case .noFoods: "Add at least one food."
        case .invalidQuantity: "Every food needs an amount above zero."
        case .missingFood: "A food in this meal is no longer available."
        case .unsupportedUnit: "One of the units can’t be converted for that food."
        }
    }
}

extension MeasureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQuantity: "Enter an amount of zero or more."
        case .unknownPortion: "That portion size is no longer available for this food."
        case .unsupportedConversion: "That unit can’t be converted for this food."
        }
    }
}

extension SQLiteError: LocalizedError {
    public var errorDescription: String? { "Your data couldn’t be read or saved (storage error \(code))." }
}
