import Foundation
import Testing
@testable import InstalogCore

@Suite("Quantity input")
struct QuantityInputTests {
    @Test func parsing() {
        #expect(QuantityInput.parse("150") == 150)
        #expect(QuantityInput.parse("1.") == 1)
        #expect(QuantityInput.parse(",5") == 0.5)
        #expect(QuantityInput.parse("12,25") == 12.25)
        for bad in ["", ".", ",", "1e5", "inf", "nan", "0x10", "1,234.5", "-1", " ", "1.2.3"] {
            #expect(QuantityInput.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func editing() {
        for ok in ["", "1", "1.", "12.5", "0,25", "999999", ".5"] {
            #expect(QuantityInput.isAcceptableEditing(ok), "\(ok)")
        }
        for bad in ["1.234", "1..2", "1.2,3", "1234567", "a", "1e5", "-2"] {
            #expect(!QuantityInput.isAcceptableEditing(bad), "\(bad)")
        }
    }

    @Test func textRoundTrips() {
        let us = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        #expect(QuantityInput.text(1234.5, locale: us) == "1234.5")
        #expect(QuantityInput.text(1234.5, locale: de) == "1234,5")
        #expect(QuantityInput.text(100, locale: us) == "100")
        #expect(QuantityInput.text(0.125, locale: us) == "0.13")
        #expect(QuantityInput.text(.infinity, locale: us) == "0")
        for value in [0, 0.5, 12.25, 1234.5, 9999.99] {
            #expect(QuantityInput.parse(QuantityInput.text(value, locale: de)) == value)
        }
    }

    @Test func clamping() {
        #expect(QuantityInput.clamp(1e12, unit: .gram) == 10_000)
        #expect(QuantityInput.clamp(-5, unit: .gram) == 0)
        #expect(QuantityInput.clamp(.nan, unit: .serving) == 0)
        #expect(QuantityInput.clamp(500, unit: .ounce) == 350)
        #expect(QuantityStep.increase(10_000, unit: .gram) == 10_000)
    }
}

@Suite("Number formatting never traps")
struct NumberFormattingSafetyTests {
    @Test func nonFinite() {
        #expect(NumberFormatting.energy(.infinity) == "—")
        #expect(NumberFormatting.quantity(.nan) == "—")
        #expect(NumberFormatting.nutrient(-.infinity) == "—")
        #expect(NumberFormatting.percent(.infinity) == nil)
    }

    @Test func hugeAndNegativeZero() {
        let us = Locale(identifier: "en_US")
        _ = NumberFormatting.nutrient(1e300)
        _ = NumberFormatting.quantity(1e300)
        _ = NumberFormatting.energy(1e300)
        #expect(NumberFormatting.energy(-0.4, locale: us) == "0")
        #expect(NumberFormatting.percent(0.5, locale: us) == "50%")
        #expect(NumberFormatting.quantity(12.5, locale: us) == "12.5")
    }
}

@Suite("Readable errors")
struct ErrorMessageTests {
    @Test func everyErrorReadsAsASentence() {
        let errors: [any Error] = [
            LoggingBusyError(), SectionNameError(), TargetValueError(), FoodInUseError(mealNames: ["Oats"]),
            EntryValidationError.noFoods, EntryValidationError.blankName, FoodValidationError.invalidBasis,
            MealValidationError.missingFood, MeasureError.unknownPortion("cup"),
            SQLiteError(code: 10, message: "disk I/O error"),
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.contains("operation couldn"), "\(type(of: error))")
            #expect(!text.contains("Error("), "\(type(of: error))")
        }
    }
}

@MainActor
@Suite("UI polish behavior")
struct PolishModelTests {
    let clock = TestClock()

    private func seeded() async throws -> (DiaryModel, Routine, SQLitePersonalStore) {
        let store = try SQLitePersonalStore(url: nil)
        let routine = try await Scenario.seedRoutine(into: store)
        return (await Scenario.model(store: store, clock: clock), routine, store)
    }

    @Test("Draft quantities are clamped and non-finite input is ignored")
    func draftClamping() async throws {
        let (model, _, _) = try await seeded()
        let item = model.draftItems[0]
        model.setDraftQuantity(1e12, for: item.id)
        #expect(model.draftItems[0].quantity == 10_000)
        model.setDraftQuantity(.infinity, for: item.id)
        #expect(model.draftItems[0].quantity == 10_000)
    }

    @Test("An all-zero log explains itself in plain words")
    func zeroLogMessage() async throws {
        let (model, _, _) = try await seeded()
        for item in model.draftItems { model.setDraftQuantity(0, for: item.id) }
        #expect(!(await model.logSelectedMeal()))
        #expect(model.errorMessage?.contains("above zero") == true)
    }

    @Test("A failed load is reported, and retrying recovers")
    func loadFailure() async throws {
        let inner = try SQLitePersonalStore(url: nil)
        try await Scenario.seedRoutine(into: inner)
        let store = ControllableStore(inner: inner)
        await store.setFailLoads(true)
        let model = await Scenario.model(store: store, clock: clock)
        #expect(!model.isLoaded)
        let message = try #require(model.loadError)
        #expect(!message.contains("SQLiteError("))
        await store.setFailLoads(false)
        await model.load()
        #expect(model.loadError == nil)
        #expect(model.isLoaded)
        #expect(model.hasSections)
    }

    @Test("Target settings read and write today, even while viewing a past day")
    func targetsUseToday() async throws {
        let (model, _, _) = try await seeded()
        try await model.setTarget(.energy, amount: 2200, kind: .target)
        clock.advance(seconds: 86_400)
        await model.refreshForCurrentDate(isIdle: true)
        await model.showAdjacentDay(-1)
        #expect(!model.isViewingToday)
        try await model.setTarget(.energy, amount: 1800, kind: .target)
        #expect(model.effectiveTargets(on: model.today)[.energy]?.amount == 1800)
        #expect(model.effectiveTargets[.energy]?.amount == 2200, "The viewed day keeps its own target")

        try await model.setTarget(.protein, amount: 150, kind: .target)
        clock.advance(seconds: 86_400)
        await model.refreshForCurrentDate(isIdle: false)
        try await model.setTarget(.protein, amount: 120, kind: .target)
        try await model.disableTarget(.protein)
        let disabled = try #require(model.targets.last { $0.nutrientID == .protein })
        #expect(!disabled.enabled)
        #expect(disabled.amount == 120)
    }

    @Test("Targets reject absurd amounts")
    func targetBounds() async throws {
        let (model, _, _) = try await seeded()
        await #expect(throws: TargetValueError.self) { try await model.setTarget(.energy, amount: 1e12, kind: .target) }
    }

    @Test("Day navigation never goes past today")
    func dayNavigation() async throws {
        let (model, _, _) = try await seeded()
        #expect(!model.canShowNextDay)
        await model.showAdjacentDay(1)
        #expect(model.isViewingToday)
        await model.changeDate(to: model.today.adding(days: 3))
        #expect(model.isViewingToday)
        await model.showAdjacentDay(-1)
        #expect(model.viewedDate == model.today.adding(days: -1))
        #expect(model.canShowNextDay)
        await model.showAdjacentDay(1)
        #expect(model.isViewingToday)
    }

    @Test("Days with entries are found within a range")
    func daysWithEntries() async throws {
        let (model, _, _) = try await seeded()
        await model.logSelectedMeal()
        await model.showAdjacentDay(-2)
        await model.logSelectedMeal()
        let days = await model.daysWithEntries(from: model.today.adding(days: -7), through: model.today)
        #expect(days == [model.today, model.today.adding(days: -2)])
        #expect(await model.daysWithEntries(from: model.today.adding(days: -1), through: model.today.adding(days: -1)).isEmpty)
    }

    @Test("Draft edits belong to the day they were made on")
    func draftsPerDay() async throws {
        let (model, _, _) = try await seeded()
        model.setDraftQuantity(90, for: model.draftItems[0].id)
        await model.showAdjacentDay(-1)
        #expect(!model.isDraftAdjusted)
        await model.showAdjacentDay(1)
        #expect(model.draftItems[0].quantity == 90)
    }

    @Test("Recent foods are newest first, once each, with the last amount")
    func recentFoods() async throws {
        let (model, routine, _) = try await seeded()
        await model.logSelectedMeal()  // oats 60, milk 200
        clock.advance(seconds: 60)
        model.selectMeal(id: routine.yogurtMeal.id)
        model.setDraftQuantity(175, for: model.draftItems[0].id)
        await model.logSelectedMeal()  // food A 175
        clock.advance(seconds: 60)
        model.selectMeal(id: routine.oatsMeal.id)
        model.setDraftQuantity(80, for: model.draftItems[0].id)
        await model.logSelectedMeal()  // oats 80, milk 200

        let recent = await model.recentFoods()
        #expect(recent.map(\.food.id) == [Fixtures.milk.id, Fixtures.oats.id, Fixtures.foodA.id])
        #expect(recent.first { $0.food.id == Fixtures.oats.id }?.quantity == 80)
        #expect(recent.first { $0.food.id == Fixtures.foodA.id }?.quantity == 175)
    }

    @Test("Renaming an entry is trimmed and persisted")
    func renameEntry() async throws {
        let (model, _, store) = try await seeded()
        await model.logSelectedMeal()
        var edited = model.entries[0]
        edited.name = "  Brunch "
        try await model.updateEntry(edited)
        #expect(model.entries[0].name == "Brunch")
        #expect(try await store.allEntries()[0].name == "Brunch")
    }

    @Test("Removing a food from an entry lowers totals; removing every food is refused")
    func removeFoodFromEntry() async throws {
        let (model, _, store) = try await seeded()
        await model.logSelectedMeal()
        let before = model.dayNutrition[.energy].known
        var edited = model.entries[0]
        edited.foods.removeAll { $0.foodID == Fixtures.milk.id }
        try await model.updateEntry(edited)
        #expect(model.entries[0].foods.count == 1)
        #expect(model.dayNutrition[.energy].known < before)

        var empty = model.entries[0]
        empty.foods = []
        await #expect(throws: EntryValidationError.noFoods) { try await model.updateEntry(empty) }
        #expect(model.entries[0].foods.count == 1)
        #expect(try await store.allEntries()[0].foods.count == 1)
    }

    @Test("Moving and editing an entry save together")
    func moveWithEdits() async throws {
        let (model, routine, store) = try await seeded()
        await model.logSelectedMeal()
        var edited = model.entries[0]
        edited.foods[0].quantity = 120
        let lunch = try #require(model.destinations.first { $0.section?.id == routine.lunch.id })
        edited.assign(to: lunch)
        try await model.updateEntry(edited)
        let saved = try #require(try await store.allEntries().first)
        #expect(saved.sectionID == routine.lunch.id)
        #expect(saved.foods[0].quantity == 120)
        #expect(model.toast?.message.contains("Lunch") == true)
    }

    @Test("Saving a custom food twice with one id updates it")
    func customFoodUpdate() async throws {
        let (model, _, _) = try await seeded()
        var food = FoodDefinition(
            source: .custom, name: "Bar", nutrition: FoodNutrition(basis: .per100Grams, nutrients: NutrientProfile([.energy: 400])))
        try await model.saveCustomFood(food)
        food.name = "Protein bar"
        try await model.saveCustomFood(food)
        #expect(model.customFoods.filter { $0.id == food.id }.map(\.name) == ["Protein bar"])
    }

    @Test("Custom foods reject absurd amounts")
    func customFoodBounds() async throws {
        let (model, _, _) = try await seeded()
        let huge = FoodDefinition(
            source: .custom, name: "Huge",
            nutrition: FoodNutrition(basis: NutritionBasis(amount: 1e9, dimension: .mass), nutrients: NutrientProfile([.energy: 1])))
        await #expect(throws: FoodValidationError.invalidBasis) { try await model.saveCustomFood(huge) }
    }

    @Test("Deleting a custom food is refused while a meal uses it, and hides it otherwise")
    func archiveCustomFood() async throws {
        let (model, routine, store) = try await seeded()
        await #expect(throws: FoodInUseError.self) { try await model.archiveCustomFood(id: Fixtures.foodB.id) }

        try await model.archiveMeal(id: routine.lunchMeal.id)
        try await model.archiveCustomFood(id: Fixtures.foodB.id)
        #expect(!model.customFoods.contains { $0.id == Fixtures.foodB.id })
        #expect(await model.searchFoods("Food B").personalFoods.isEmpty)

        let data = try await model.exportData()
        let decoded = try ExportService.decode(data)
        try ExportService.validate(decoded)
        #expect(decoded.foods.contains { $0.id == Fixtures.foodB.id && $0.isArchived })
        _ = store
    }

    @Test("Foods saved before archiving existed still decode")
    func legacyFoodDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Fixtures.foodA)) as! [String: Any]
        json.removeValue(forKey: "archivedAt")
        let food = try JSONDecoder().decode(FoodDefinition.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!food.isArchived)
    }
}

@Suite("Unit conversion keeps the amount")
struct UnitConversionTests {
    @Test func convertsBetweenUnits() {
        let milk = Fixtures.milk.nutrition
        #expect(milk.convert(quantity: 244, from: .gram, to: .portion(id: "cup")) == 1)
        #expect(milk.convert(quantity: 2, from: .portion(id: "cup"), to: .gram) == 488)
        #expect(milk.convert(quantity: 1, from: .ounce, to: .gram) == 28.35)
        #expect(milk.convert(quantity: 100, from: .gram, to: .milliliter) == nil, "No density, no guessing")
    }
}
