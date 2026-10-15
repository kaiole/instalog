import Foundation
import Testing
@testable import InstalogCore

@Suite("Persistence and export")
struct PersistenceTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("instalog-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("personal.sqlite")
    }

    private func sampleEntry(date: LogDate, section: RoutineSection?, quantity: Double = 50) -> LoggedEntry {
        LoggedEntry(
            logDate: date, recordedAt: Date(), sectionID: section?.id, sectionName: section?.name,
            mealTemplateID: nil, name: "Food A", path: .additional,
            foods: [LoggedFoodSnapshot(food: Fixtures.foodA, quantity: quantity, unit: .gram)])
    }

    @Test("AT-18: committed data survives reopening the store")
    func survivesRestart() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let day = LogDate(year: 2026, month: 10, day: 1)
        do {
            let store = try SQLitePersonalStore(url: url)
            let routine = try await Scenario.seedRoutine(into: store)
            try await store.apply([
                .putEntry(sampleEntry(date: day, section: routine.breakfast)),
                .putPreferences(AppPreferences(autoProgression: true)),
            ])
        }
        let reopened = try SQLitePersonalStore(url: url)
        let configuration = try await reopened.loadConfiguration()
        #expect(configuration.sections.map(\.name) == ["Breakfast", "Lunch", "Snack", "Dinner"])
        #expect(configuration.meals.count == 4)
        #expect(configuration.preferences.autoProgression)
        #expect(try await reopened.entries(on: day).count == 1)
    }

    @Test("Entries are queried by day")
    func entriesByDay() async throws {
        let store = try SQLitePersonalStore(url: nil)
        let day = LogDate(year: 2026, month: 10, day: 1)
        try await store.apply([
            .putEntry(sampleEntry(date: day, section: nil)),
            .putEntry(sampleEntry(date: day.adding(days: -1), section: nil)),
        ])
        #expect(try await store.entries(on: day).count == 1)
        #expect(try await store.allEntries().count == 2)
    }

    @Test("A failing batch writes nothing")
    func atomicBatch() async throws {
        let store = try SQLitePersonalStore(url: nil)
        let day = LogDate(year: 2026, month: 10, day: 1)
        let good = sampleEntry(date: day, section: nil)
        // A food whose JSON cannot be encoded (NaN) fails mid-batch, after the entry insert.
        var broken = Fixtures.foodB
        broken.nutrition.nutrients[.protein] = .nan
        await #expect(throws: (any Error).self) {
            try await store.apply([.putEntry(good), .putFood(broken)])
        }
        #expect(try await store.entries(on: day).isEmpty)
    }

    @Test("AT-31: export then import round-trips entries, snapshots, order, targets and unknowns")
    func roundTrip() async throws {
        let source = try SQLitePersonalStore(url: nil)
        let routine = try await Scenario.seedRoutine(into: source)
        let day = LogDate(year: 2026, month: 10, day: 1)
        let target = NutritionTarget(
            nutrientID: .energy, kind: .target, amount: 2200, unit: .kilocalorie, effectiveDate: .beginning)
        try await source.apply([
            .putEntry(sampleEntry(date: day, section: routine.breakfast, quantity: 37.25)),
            .putTarget(target),
            .putPreferences(AppPreferences(autoProgression: true, summaryNutrients: [.fiber, .magnesium])),
        ])
        let configuration = try await source.loadConfiguration()
        let original = PersonalDataSet(
            foods: configuration.foods, meals: configuration.meals, sections: configuration.sections,
            entries: try await source.allEntries(), targets: configuration.targets,
            preferences: configuration.preferences)

        let file = try ExportService.encode(original)
        let decoded = try ExportService.decode(file)
        let destination = try SQLitePersonalStore(url: nil)
        try await destination.replaceAll(with: decoded)

        let restored = try await destination.loadConfiguration()
        #expect(restored.sections.map(\.id) == configuration.sections.map(\.id))
        #expect(restored.sections.map(\.mealIDs) == configuration.sections.map(\.mealIDs))
        #expect(restored.meals.map(\.items) == configuration.meals.map(\.items))
        #expect(restored.targets == configuration.targets)
        #expect(restored.preferences == configuration.preferences)
        let entries = try await destination.entries(on: day)
        #expect(entries == original.entries)
        let summary = NutritionCalculator.summarize(entries: entries)
        #expect(summary[.vitaminC].completeness == .unknown)
        #expect(summary[.magnesium].known.isClose(to: 40 * 0.3725))
        #expect(String(data: file, encoding: .utf8)!.contains("\"schemaVersion\" : 2"))
    }

    @Test("AT-32: unsupported or invalid imports fail without touching the store")
    func invalidImport() async throws {
        let store = try SQLitePersonalStore(url: nil)
        try await Scenario.seedRoutine(into: store)
        let before = try await store.loadConfiguration()

        #expect(throws: ImportError.corrupt("not valid JSON")) { try ExportService.decode(Data("nope".utf8)) }
        #expect(throws: ImportError.notAnExport) { try ExportService.decode(Data(#"{"format":"other"}"#.utf8)) }
        #expect(throws: ImportError.unsupportedVersion(99)) {
            try ExportService.decode(Data(#"{"format":"instalog-personal-data","schemaVersion":99}"#.utf8))
        }

        var bad = PersonalDataSet(foods: [Fixtures.foodA])
        bad.meals = [Fixtures.meal("Broken", [(Fixtures.foodB, 10)], order: 0)]
        let file = try ExportService.encode(bad)
        #expect(throws: ImportError.self) { try ExportService.decode(file) }

        var negative = PersonalDataSet(foods: [Fixtures.foodA])
        negative.entries = [sampleEntry(date: LogDate(year: 2026, month: 1, day: 1), section: nil, quantity: -5)]
        #expect(throws: ImportError.self) { try ExportService.decode(try ExportService.encode(negative)) }

        #expect(try await store.loadConfiguration() == before)
    }

    @Test("Custom food validation follows ADD-08")
    func customFoodValidation() {
        let basis = NutritionBasis.per100Grams
        #expect(throws: FoodValidationError.blankName) {
            try FoodDefinition.validateCustom(name: "  ", nutrition: FoodNutrition(basis: basis, nutrients: NutrientProfile([.energy: 1])))
        }
        #expect(throws: FoodValidationError.noNutrients) {
            try FoodDefinition.validateCustom(name: "Bar", nutrition: FoodNutrition(basis: basis, nutrients: NutrientProfile()))
        }
        #expect(throws: FoodValidationError.invalidNutrientValue) {
            try FoodDefinition.validateCustom(name: "Bar", nutrition: FoodNutrition(basis: basis, nutrients: NutrientProfile([.energy: -1])))
        }
        #expect(throws: FoodValidationError.invalidBasis) {
            try FoodDefinition.validateCustom(
                name: "Bar", nutrition: FoodNutrition(basis: NutritionBasis(amount: 0, dimension: .mass), nutrients: NutrientProfile([.energy: 1])))
        }
        #expect(throws: Never.self) {
            try FoodDefinition.validateCustom(name: "Bar", nutrition: FoodNutrition(basis: basis, nutrients: NutrientProfile([.protein: 0])))
        }
    }

    @Test("Saved meals need a name, a food and positive supported quantities")
    func mealValidation() {
        let foods = [Fixtures.foodA.id: Fixtures.foodA]
        #expect(throws: MealValidationError.blankName) {
            try Fixtures.meal(" ", [(Fixtures.foodA, 10)], order: 0).validate(foods: foods)
        }
        #expect(throws: MealValidationError.noFoods) {
            try MealTemplate(name: "Empty", items: [], sortOrder: 0).validate(foods: foods)
        }
        #expect(throws: MealValidationError.invalidQuantity) {
            try Fixtures.meal("Zero", [(Fixtures.foodA, 0)], order: 0).validate(foods: foods)
        }
        let volume = MealTemplate(
            name: "Volume", items: [MealTemplateItem(foodID: Fixtures.foodA.id, defaultQuantity: 100, unit: .milliliter)],
            sortOrder: 0)
        #expect(throws: MealValidationError.unsupportedUnit) { try volume.validate(foods: foods) }
    }
}
