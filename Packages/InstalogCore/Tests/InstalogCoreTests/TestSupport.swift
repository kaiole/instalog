import Foundation
@testable import InstalogCore

/// Deterministic synthetic foods from a fixed numeric fixture.
enum Fixtures {
    static let foodA = FoodDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, source: .custom, name: "Food A",
        nutrition: FoodNutrition(
            basis: .per100Grams,
            nutrients: NutrientProfile([.energy: 200, .protein: 10, .magnesium: 40]),
            portions: [FoodPortion(id: "scoop", name: "scoop", grams: 30)]))

    static let foodB = FoodDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, source: .custom, name: "Food B",
        nutrition: FoodNutrition(basis: .per100Grams, nutrients: NutrientProfile([.energy: 100, .protein: 2])))

    static let oats = FoodDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!, source: .custom, name: "Oats",
        nutrition: FoodNutrition(
            basis: .per100Grams, nutrients: NutrientProfile([.energy: 379, .protein: 13, .carbohydrate: 68, .fat: 6.5])))

    static let milk = FoodDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, source: .custom, name: "Milk",
        nutrition: FoodNutrition(
            basis: .per100Grams, nutrients: NutrientProfile([.energy: 61, .protein: 3.2, .carbohydrate: 4.8, .fat: 3.3]),
            portions: [FoodPortion(id: "cup", name: "cup", grams: 244)]))

    static var allFoods: [FoodDefinition] { [foodA, foodB, oats, milk] }

    static func meal(_ name: String, _ items: [(FoodDefinition, Double)], order: Int) -> MealTemplate {
        MealTemplate(
            name: name,
            items: items.map { MealTemplateItem(foodID: $0.0.id, defaultQuantity: $0.1, unit: .gram) },
            sortOrder: order, createdAt: Date(timeIntervalSince1970: Double(order)))
    }
}

/// A controllable clock. Starts at 2026-10-01 09:00 local time.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = TestClock.date(2026, 10, 1, hour: 9)) { current = date }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

/// Wraps a real store and can fail or delay writes on demand.
actor ControllableStore: PersonalStore {
    let inner: SQLitePersonalStore
    var failApplies = false
    var applyDelayNanoseconds: UInt64 = 0
    private(set) var applyCount = 0

    init(inner: SQLitePersonalStore) {
        self.inner = inner
    }

    func setFailApplies(_ value: Bool) { failApplies = value }
    func setDelay(_ nanoseconds: UInt64) { applyDelayNanoseconds = nanoseconds }

    func loadConfiguration() async throws -> PersonalConfiguration { try await inner.loadConfiguration() }
    func entries(on date: LogDate) async throws -> [LoggedEntry] { try await inner.entries(on: date) }
    func allEntries() async throws -> [LoggedEntry] { try await inner.allEntries() }

    func apply(_ operations: [StoreOperation]) async throws {
        applyCount += 1
        if applyDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: applyDelayNanoseconds) }
        if failApplies { throw SQLiteError(code: 10, message: "simulated disk I/O error") }
        try await inner.apply(operations)
    }

    func replaceAll(with data: PersonalDataSet) async throws {
        if failApplies { throw SQLiteError(code: 10, message: "simulated disk I/O error") }
        try await inner.replaceAll(with: data)
    }
}

struct Routine {
    var oatsMeal: MealTemplate
    var yogurtMeal: MealTemplate
    var shakeMeal: MealTemplate
    var lunchMeal: MealTemplate
    var breakfast: RoutineSection
    var lunch: RoutineSection
    var snack: RoutineSection
    var dinner: RoutineSection
}

enum Scenario {
    /// Saves foods, four meals and Breakfast / Lunch / Snack / Dinner (Dinner has no meals).
    @discardableResult
    static func seedRoutine(into store: any PersonalStore) async throws -> Routine {
        let oatsMeal = Fixtures.meal("Oats + milk", [(Fixtures.oats, 60), (Fixtures.milk, 200)], order: 0)
        let yogurtMeal = Fixtures.meal("Yogurt", [(Fixtures.foodA, 150)], order: 1)
        let shakeMeal = Fixtures.meal("Protein shake", [(Fixtures.foodA, 30), (Fixtures.milk, 250)], order: 2)
        let lunchMeal = Fixtures.meal("Lunch bowl", [(Fixtures.foodB, 300)], order: 3)
        let breakfast = RoutineSection(name: "Breakfast", sortOrder: 0, mealIDs: [oatsMeal.id, yogurtMeal.id, shakeMeal.id])
        let lunch = RoutineSection(name: "Lunch", sortOrder: 1, mealIDs: [lunchMeal.id])
        let snack = RoutineSection(name: "Snack", sortOrder: 2, mealIDs: [shakeMeal.id])
        let dinner = RoutineSection(name: "Dinner", sortOrder: 3)
        var operations = Fixtures.allFoods.map(StoreOperation.putFood)
        operations += [oatsMeal, yogurtMeal, shakeMeal, lunchMeal].map(StoreOperation.putMeal)
        operations += [breakfast, lunch, snack, dinner].map(StoreOperation.putSection)
        try await store.apply(operations)
        return Routine(
            oatsMeal: oatsMeal, yogurtMeal: yogurtMeal, shakeMeal: shakeMeal, lunchMeal: lunchMeal,
            breakfast: breakfast, lunch: lunch, snack: snack, dinner: dinner)
    }

    @MainActor
    static func model(store: any PersonalStore, clock: TestClock, catalog: (any FoodCatalog)? = nil) async -> DiaryModel {
        let model = DiaryModel(store: store, catalog: catalog, clock: { clock.now })
        await model.load()
        return model
    }
}

extension Double {
    func isClose(to other: Double, tolerance: Double = 1e-9) -> Bool { abs(self - other) <= tolerance }
}
