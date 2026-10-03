import Foundation

public struct ExportDocument: Codable, Sendable {
    public static let formatName = "instalog-personal-data"
    public static let currentSchemaVersion = 1

    /// Timestamps are encoded as exact numbers so a round trip is lossless.
    public static let timestampEncoding = "seconds since 2001-01-01T00:00:00Z"

    public var format: String
    public var schemaVersion: Int
    public var timestampEncoding: String
    public var exportedAt: Date
    /// Human-readable copy of `exportedAt`; informational only.
    public var exportedAtISO8601: String
    public var data: PersonalDataSet

    public init(data: PersonalDataSet, exportedAt: Date = Date()) {
        format = Self.formatName
        schemaVersion = Self.currentSchemaVersion
        timestampEncoding = Self.timestampEncoding
        self.exportedAt = exportedAt
        exportedAtISO8601 = exportedAt.formatted(.iso8601)
        self.data = data
    }
}

public enum ImportError: Error, Equatable, LocalizedError, Sendable {
    case notAnExport
    case unsupportedVersion(Int)
    case corrupt(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notAnExport: "This file isn’t an Instalog export."
        case .unsupportedVersion(let version): "This export uses schema version \(version), which this app can’t read."
        case .corrupt(let detail): "The file is damaged: \(detail)"
        case .invalid(let detail): "The export contains invalid data: \(detail)"
        }
    }
}

public struct ImportPreview: Sendable, Equatable {
    public var foods: Int
    public var meals: Int
    public var sections: Int
    public var entries: Int
    public var targets: Int
    public var firstDay: LogDate?
    public var lastDay: LogDate?
}

/// Lossless, versioned JSON export of personal data and validated full-replacement import.
public enum ExportService {
    public static func encode(_ data: PersonalDataSet, exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(ExportDocument(data: data, exportedAt: exportedAt))
    }

    /// Parses and fully validates an export without touching any store.
    public static func decode(_ fileData: Data) throws -> PersonalDataSet {
        struct Header: Decodable {
            var format: String?
            var schemaVersion: Int?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: fileData) else {
            throw ImportError.corrupt("not valid JSON")
        }
        guard header.format == ExportDocument.formatName else { throw ImportError.notAnExport }
        guard let version = header.schemaVersion, version == ExportDocument.currentSchemaVersion else {
            throw ImportError.unsupportedVersion(header.schemaVersion ?? 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let document: ExportDocument
        do {
            document = try decoder.decode(ExportDocument.self, from: fileData)
        } catch {
            throw ImportError.corrupt(String(describing: error))
        }
        try validate(document.data)
        return document.data
    }

    public static func preview(_ data: PersonalDataSet) -> ImportPreview {
        let days = data.entries.map(\.logDate)
        return ImportPreview(
            foods: data.foods.count, meals: data.meals.filter { !$0.isArchived }.count,
            sections: data.sections.filter { !$0.isArchived }.count, entries: data.entries.count,
            targets: data.targets.count, firstDay: days.min(), lastDay: days.max())
    }

    public static func validate(_ data: PersonalDataSet) throws {
        try requireUnique(data.foods.map(\.id), "food")
        try requireUnique(data.meals.map(\.id), "meal")
        try requireUnique(data.sections.map(\.id), "section")
        try requireUnique(data.entries.map(\.id), "entry")
        try requireUnique(data.targets.map(\.id), "target")

        let foods = Dictionary(uniqueKeysWithValues: data.foods.map { ($0.id, $0) })
        for food in data.foods where !food.nutrition.isValid {
            throw ImportError.invalid("food “\(food.name)” has invalid nutrition data")
        }
        for meal in data.meals {
            do {
                try meal.validate(foods: foods)
            } catch {
                throw ImportError.invalid("meal “\(meal.name)” is invalid: \(error.localizedDescription)")
            }
        }
        let mealIDs = Set(data.meals.map(\.id))
        for section in data.sections {
            if section.name.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ImportError.invalid("a section has no name")
            }
            if let missing = section.mealIDs.first(where: { !mealIDs.contains($0) }) {
                throw ImportError.invalid("section “\(section.name)” references unknown meal \(missing)")
            }
            if Set(section.mealIDs).count != section.mealIDs.count {
                throw ImportError.invalid("section “\(section.name)” lists a meal twice")
            }
        }
        for entry in data.entries {
            do {
                try entry.validate()
            } catch {
                throw ImportError.invalid("entry “\(entry.name)” on \(entry.logDate) is invalid: \(error.localizedDescription)")
            }
        }
        for target in data.targets {
            guard target.isValid else { throw ImportError.invalid("target for \(target.nutrientID) is invalid") }
            guard NutrientRegistry.definition(for: target.nutrientID) != nil else {
                throw ImportError.invalid("target references unknown nutrient \(target.nutrientID)")
            }
        }
        let summary = data.preferences.summaryNutrients
        if summary.count > AppPreferences.maxSummaryNutrients
            || summary.contains(where: { NutrientRegistry.definition(for: $0) == nil })
        {
            throw ImportError.invalid("summary nutrient preferences are invalid")
        }
    }

    private static func requireUnique(_ ids: [UUID], _ kind: String) throws {
        if Set(ids).count != ids.count { throw ImportError.invalid("duplicate \(kind) IDs") }
    }
}
