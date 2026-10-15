import Foundation

/// How a calorie target and macro targets fit together at 4 / 4 / 9 kcal per gram.
///
/// Nothing here changes a value on its own: it reports whether the targets add up and, when
/// they don't, offers fixes the user can choose. With all three macros set they must match the
/// calorie target; with some turned off, the ones set just can't need more than it.
/// Logged food is never checked against this; labels round and count fiber differently.
public struct MacroBalance: Equatable, Sendable {
    public static let macros: [NutrientID] = [.protein, .carbohydrate, .fat]

    public static func kcalPerGram(_ macro: NutrientID) -> Double {
        macro == .fat ? 9 : 4
    }

    public enum Status: Equatable, Sendable {
        /// No calorie target, or no macro targets: there's nothing to compare.
        case unchecked
        /// Macros add up to the calorie target, within rounding.
        case matches
        /// Macros need more energy than the calorie target. Never saved.
        case over(kcal: Double)
        /// Macros need less energy than the calorie target. Fine while a macro is off (e.g.
        /// only protein is set); with all three set it's a mismatch and isn't saved.
        case under(kcal: Double)
    }

    public enum Fix: Equatable, Sendable {
        case setCalories(Double)
        /// Lowers (when over) or raises (when under) one macro so the targets add up.
        case setMacro(NutrientID, grams: Double)
    }

    public var energy: Double?
    public var protein: Double?
    public var carbohydrate: Double?
    public var fat: Double?

    public init(energy: Double? = nil, protein: Double? = nil, carbohydrate: Double? = nil, fat: Double? = nil) {
        self.energy = energy
        self.protein = protein
        self.carbohydrate = carbohydrate
        self.fat = fat
    }

    public init(targets: [NutrientID: EffectiveTarget]) {
        self.init(
            energy: targets[.energy]?.amount, protein: targets[.protein]?.amount,
            carbohydrate: targets[.carbohydrate]?.amount, fat: targets[.fat]?.amount)
    }

    public subscript(id: NutrientID) -> Double? {
        get {
            switch id {
            case .energy: energy
            case .protein: protein
            case .carbohydrate: carbohydrate
            case .fat: fat
            default: nil
            }
        }
        set {
            switch id {
            case .energy: energy = newValue
            case .protein: protein = newValue
            case .carbohydrate: carbohydrate = newValue
            case .fat: fat = newValue
            default: break
            }
        }
    }

    /// Energy from the macros that are set.
    public var macroKcal: Double {
        Self.macros.reduce(0) { sum, id in sum + (self[id] ?? 0) * Self.kcalPerGram(id) }
    }

    public var hasMacros: Bool { Self.macros.contains { self[$0] != nil } }
    public var hasAllMacros: Bool { Self.macros.allSatisfy { self[$0] != nil } }

    /// Rounding allowance: 2% of the calorie target or 50 kcal, whichever is larger.
    public var tolerance: Double { max(50, (energy ?? 0) * 0.02) }

    public var status: Status {
        guard let energy, hasMacros else { return .unchecked }
        let difference = macroKcal - energy
        if difference > tolerance { return .over(kcal: difference) }
        if difference < -tolerance { return .under(kcal: -difference) }
        return .matches
    }

    /// False when the targets contradict each other: macros needing more than the calorie
    /// target, or all three macros set and adding up to less. Unusual splits are consistent.
    public var isConsistent: Bool {
        switch status {
        case .over: false
        case .under: !hasAllMacros
        case .matches, .unchecked: true
        }
    }

    /// Ways to make inconsistent targets add up: set calories to what the macros need, or change
    /// one macro (the one just edited, else the one contributing the most energy) to fit.
    public func fixes(lastEdited: NutrientID? = nil) -> [Fix] {
        guard !isConsistent, let energy else { return [] }
        let isOver = macroKcal > energy
        var result: [Fix] = [.setCalories(macroKcal.rounded(isOver ? .up : .down))]
        let candidates = Self.macros.filter { self[$0] != nil }
            .sorted { ($0 == lastEdited ? 1 : 0, self.kcal(of: $0)) > ($1 == lastEdited ? 1 : 0, self.kcal(of: $1)) }
        for macro in candidates {
            let others = macroKcal - kcal(of: macro)
            let grams = ((energy - others) / Self.kcalPerGram(macro)).rounded(isOver ? .down : .up)
            if grams >= 0 {
                result.append(.setMacro(macro, grams: grams))
                break
            }
        }
        return result
    }

    public func applying(_ fix: Fix) -> MacroBalance {
        var copy = self
        switch fix {
        case .setCalories(let kcal): copy.energy = kcal
        case .setMacro(let macro, let grams): copy[macro] = grams
        }
        return copy
    }

    private func kcal(of macro: NutrientID) -> Double { (self[macro] ?? 0) * Self.kcalPerGram(macro) }

    // MARK: Percent of calories

    public static func grams(percent: Double, of energy: Double, macro: NutrientID) -> Double {
        energy * percent / 100 / kcalPerGram(macro)
    }

    public static func percent(grams: Double, of energy: Double, macro: NutrientID) -> Double {
        guard energy > 0 else { return 0 }
        return grams * kcalPerGram(macro) / energy * 100
    }
}

/// Calorie and macro targets that don't add up. Never saved.
public struct MacroBalanceError: Error, Equatable {
    /// Macro energy minus the calorie target: positive when over, negative when under.
    public let difference: Double
}
