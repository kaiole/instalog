import Foundation

/// How macro targets are entered. Either way they're stored as grams.
public enum MacroTargetMode: String, Hashable, Sendable, Codable {
    case grams
    case percent
}

public struct AppPreferences: Hashable, Sendable, Codable {
    public static let maxSummaryNutrients = 3

    public var autoProgression: Bool
    public var summaryNutrients: [NutrientID]
    /// Show FDA reference values for nutrients without a personal target.
    public var showReferenceValues: Bool
    public var macroTargetMode: MacroTargetMode

    public init(
        autoProgression: Bool = false, summaryNutrients: [NutrientID] = [.protein, .carbohydrate, .fat],
        showReferenceValues: Bool = true, macroTargetMode: MacroTargetMode = .grams
    ) {
        self.autoProgression = autoProgression
        self.summaryNutrients = summaryNutrients
        self.showReferenceValues = showReferenceValues
        self.macroTargetMode = macroTargetMode
    }

    private enum CodingKeys: String, CodingKey {
        case autoProgression, summaryNutrients, showReferenceValues, macroTargetMode
    }

    /// Fields added after the first release default when missing, so older data still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        autoProgression = try container.decode(Bool.self, forKey: .autoProgression)
        summaryNutrients = try container.decode([NutrientID].self, forKey: .summaryNutrients)
        showReferenceValues = try container.decode(Bool.self, forKey: .showReferenceValues)
        macroTargetMode = try container.decodeIfPresent(MacroTargetMode.self, forKey: .macroTargetMode)
            ?? defaults.macroTargetMode
    }
}

/// Same-day navigation memory: which section was last viewed and which meal each section had
/// selected. Ignored on a new day.
public struct NavigationMemory: Hashable, Sendable, Codable {
    public var date: LogDate
    public var sectionID: UUID?
    /// Keyed by section ID string, or `SectionKey.unsectioned`.
    public var mealSelections: [String: UUID]

    public init(date: LogDate, sectionID: UUID? = nil, mealSelections: [String: UUID] = [:]) {
        self.date = date
        self.sectionID = sectionID
        self.mealSelections = mealSelections
    }
}

public enum SectionKey {
    public static let unsectioned = "unsectioned"

    public static func key(for sectionID: UUID?) -> String {
        sectionID?.uuidString ?? unsectioned
    }
}
