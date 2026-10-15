import Foundation
import Testing
@testable import InstalogCore

@Suite("Bundled USDA catalog")
struct CatalogTests {
    private let catalog: SQLiteFoodCatalog

    init() throws {
        catalog = try SQLiteFoodCatalog.bundled()
    }

    @Test("Search finds common foods with distinguishing identity")
    func search() async throws {
        let results = try await catalog.search("banana", limit: 10)
        let raw = try #require(results.first { $0.name == "Bananas, raw" })
        #expect(raw.preparation == "raw")
        #expect(raw.sourceLabel == "USDA SR Legacy")
        #expect(raw.category == "Fruits and Fruit Juices")
        #expect(raw.energyPer100Grams == 89)
    }

    @Test("Raw and cooked foods are separate records, not merged")
    func rawVersusCooked() async throws {
        let results = try await catalog.search("broccoli raw", limit: 10)
        #expect(results.contains { $0.name == "Broccoli, raw" })
        let cooked = try await catalog.search("broccoli cooked boiled", limit: 10)
        #expect(cooked.allSatisfy { $0.name != "Broccoli, raw" })
    }

    @Test("Empty and punctuation-only queries return no results without error")
    func emptyQuery() async throws {
        #expect(try await catalog.search("", limit: 10).isEmpty)
        #expect(try await catalog.search("\"*()", limit: 10).isEmpty)
        #expect(try await catalog.search("zzqxj", limit: 10).isEmpty)
    }

    @Test("Food records keep sparse nutrients, provenance and normalized portions")
    func foodDetail() async throws {
        let whey = try #require(try await catalog.food(id: "173177"))
        #expect(whey.sourceDataType == "SR Legacy")
        #expect(whey.sourceVersion == "2018-04")
        let scoop = try #require(whey.nutrition.portions.first { $0.name == "scoop" })
        #expect(scoop.grams!.isClose(to: 86.0 / 3.0))

        let banana = try #require(try await catalog.food(id: "173944"))
        #expect(banana.nutrition.nutrients[.energy] == 89)
        #expect(banana.nutrition.nutrients[.magnesium] == 27)
        #expect(banana.nutrition.nutrients[.iodine] == nil, "SR Legacy has no iodine; it must stay unknown")
        #expect(banana.derivations[.energy] != nil)
        let medium = try #require(banana.nutrition.portions.first { $0.name.hasPrefix("medium") })
        #expect(try banana.nutrition.nutrients(quantity: 1, unit: .portion(id: medium.id))[.energy]!.isClose(to: 89 * 1.18))
    }

    @Test("FTS query escaping")
    func ftsQuery() {
        #expect(SQLiteFoodCatalog.ftsQuery(for: "Greek yogurt") == "\"greek\"* \"yogurt\"*")
        #expect(SQLiteFoodCatalog.ftsQuery(for: "  ") == nil)
    }

    @Test("Demo routine builds from real records")
    func demoRoutine() async throws {
        let routine = try await DemoRoutine.build(catalog: catalog, now: Date())
        #expect(routine.meals.count == 8)
        #expect(routine.sections.map(\.name) == ["Breakfast", "Lunch", "Snack", "Dinner"])
        let foods = Dictionary(uniqueKeysWithValues: routine.foods.map { ($0.id, $0) })
        for meal in routine.meals {
            #expect(throws: Never.self) { try meal.validate(foods: foods) }
        }
        #expect(routine.meals.first { $0.name == "Overnight oats" }?.items.count == 4)
        let targets = Dictionary(uniqueKeysWithValues: routine.targets.map { ($0.nutrientID, $0.amount) })
        let balance = MacroBalance(
            energy: targets[.energy], protein: targets[.protein], carbohydrate: targets[.carbohydrate], fat: targets[.fat])
        #expect(balance.status == .matches, "Demo targets add up at 4 / 4 / 9")
    }
}
