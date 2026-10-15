import Foundation
import Testing
@testable import InstalogCore

@Suite("Macro balance")
struct MacroBalanceTests {
    @Test("Macros are checked at 4 / 4 / 9 kcal per gram, within rounding")
    func matches() {
        let balance = MacroBalance(energy: 2200, protein: 150, carbohydrate: 238, fat: 72)
        #expect(balance.macroKcal == 2200)
        #expect(balance.status == .matches)
        // 35 kcal off on 2,200 is inside the 50 kcal allowance.
        #expect(MacroBalance(energy: 2200, protein: 150, carbohydrate: 240, fat: 75).status == .matches)
        // 2% of a large target is wider than 50 kcal.
        #expect(MacroBalance(energy: 4000, protein: 0, carbohydrate: 1020, fat: 0).status == .matches)
    }

    @Test("Macros needing more energy than the calorie target are a contradiction")
    func over() {
        let balance = MacroBalance(energy: 1000, protein: 500)
        #expect(balance.status == .over(kcal: 1000))
        #expect(!balance.isConsistent)
        #expect(balance.fixes() == [.setCalories(2000), .setMacro(.protein, grams: 250)])
        for fix in balance.fixes() {
            #expect(balance.applying(fix).isConsistent, "\(fix)")
        }
    }

    @Test("The fix lowers the macro just edited when that can fit")
    func fixPrefersLastEdited() {
        let balance = MacroBalance(energy: 2000, protein: 150, carbohydrate: 300, fat: 80)
        // 600 + 1200 + 720 = 2,520 kcal
        #expect(balance.fixes(lastEdited: .fat) == [.setCalories(2520), .setMacro(.fat, grams: 22)])
        #expect(balance.fixes() == [.setCalories(2520), .setMacro(.carbohydrate, grams: 170)])
        // Fat alone can't absorb 1,000 kcal over when it only supplies 180.
        let tight = MacroBalance(energy: 1000, protein: 200, carbohydrate: 250, fat: 20)
        #expect(tight.fixes(lastEdited: .fat) == [.setCalories(1980), .setMacro(.carbohydrate, grams: 5)])
    }

    @Test("With all three macros set, falling short of calories is a mismatch too")
    func underWithAllMacros() {
        // 400 + 400 + 450 = 1,250 kcal against 2,200.
        let balance = MacroBalance(energy: 2200, protein: 100, carbohydrate: 100, fat: 50)
        #expect(balance.status == .under(kcal: 950))
        #expect(!balance.isConsistent)
        #expect(balance.fixes() == [.setCalories(1250), .setMacro(.fat, grams: 156)])
        #expect(balance.fixes(lastEdited: .carbohydrate) == [.setCalories(1250), .setMacro(.carbohydrate, grams: 338)])
        for fix in balance.fixes(lastEdited: .carbohydrate) {
            #expect(balance.applying(fix).status == .matches, "\(fix)")
        }
    }

    @Test("Unassigned calories and unusual splits are fine")
    func underAndUnusual() {
        #expect(MacroBalance(energy: 2000, protein: 150).status == .under(kcal: 1400))
        #expect(MacroBalance(energy: 2000, protein: 150).isConsistent, "Carbs and fat are off, so the rest is unassigned")
        #expect(MacroBalance(energy: 2000, protein: 150).fixes().isEmpty)
        // Keto: 5% carbs, 75% fat.
        let keto = MacroBalance(
            energy: 2000, protein: MacroBalance.grams(percent: 20, of: 2000, macro: .protein),
            carbohydrate: MacroBalance.grams(percent: 5, of: 2000, macro: .carbohydrate),
            fat: MacroBalance.grams(percent: 75, of: 2000, macro: .fat))
        #expect(keto.status == .matches)
        #expect(MacroBalance(protein: 500).status == .unchecked, "No calorie target, nothing to compare")
        #expect(MacroBalance(energy: 1500).status == .unchecked)
    }

    @Test("Percentages round-trip through grams")
    func percentRoundTrip() {
        for macro in MacroBalance.macros {
            let grams = MacroBalance.grams(percent: 30, of: 2150, macro: macro)
            #expect(MacroBalance.percent(grams: grams, of: 2150, macro: macro).isClose(to: 30))
        }
        #expect(MacroBalance.percent(grams: 100, of: 0, macro: .protein) == 0)
    }

    @Test("Preferences saved before macro modes existed still decode")
    func legacyPreferences() throws {
        let json = #"{"autoProgression":true,"summaryNutrients":["protein"],"showReferenceValues":false}"#
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        #expect(decoded.autoProgression)
        #expect(decoded.macroTargetMode == .grams)
    }
}

@MainActor
@Suite("Refinements")
struct RefinementModelTests {
    let clock = TestClock()

    private func seeded() async throws -> (DiaryModel, Routine, SQLitePersonalStore) {
        let store = try SQLitePersonalStore(url: nil)
        let routine = try await Scenario.seedRoutine(into: store)
        return (await Scenario.model(store: store, clock: clock), routine, store)
    }

    @Test("Calories and macros save together and reject contradictions")
    func macroTargets() async throws {
        let (model, _, store) = try await seeded()
        try await model.setMacroTargets(MacroBalance(energy: 2000, protein: 150, carbohydrate: 200, fat: 67))
        #expect(model.macroBalance().status == .matches)

        await #expect(throws: MacroBalanceError.self) {
            try await model.setMacroTargets(MacroBalance(energy: 1000, protein: 500, carbohydrate: 200, fat: 67))
        }
        await #expect(throws: MacroBalanceError.self) {
            try await model.setMacroTargets(MacroBalance(energy: 2200, protein: 100, carbohydrate: 100, fat: 50))
        }
        #expect(model.effectiveTargets(on: model.today)[.energy]?.amount == 2000, "Nothing changed")

        // Turning carbs and fat off leaves calories and protein.
        try await model.setMacroTargets(MacroBalance(energy: 2000, protein: 150))
        let targets = model.effectiveTargets(on: model.today)
        #expect(targets[.carbohydrate] == nil)
        #expect(targets[.fat] == nil)
        #expect(targets[.protein]?.amount == 150)

        let reloaded = await Scenario.model(store: store, clock: clock)
        #expect(reloaded.macroBalance() == MacroBalance(energy: 2000, protein: 150))
    }

    @Test("Logging on a future day files an ordinary entry there")
    func futureLogging() async throws {
        let (model, _, store) = try await seeded()
        let later = model.today.adding(days: 45)
        await model.changeDate(to: later)
        #expect(await model.logSelectedMeal())
        #expect(model.entries.count == 1)
        #expect(try await store.entries(on: later).count == 1)
        #expect(try await store.entries(on: model.today).isEmpty)
    }

    @Test("Inline edits preview day totals and save only when asked")
    func inlineEditing() async throws {
        let (model, _, store) = try await seeded()
        await model.logSelectedMeal()
        let entry = try #require(model.entries.first)
        let saved = model.dayNutrition[.energy].known

        model.beginEditing(entry)
        #expect(model.entryEditDayNutrition == nil, "No preview without changes")
        let oats = entry.foods[0]
        model.setEditQuantity(oats.quantity / 2, for: oats.id)
        let preview = try #require(model.entryEditDayNutrition)
        #expect(preview[.energy].known < saved)
        #expect(model.dayNutrition[.energy].known == saved, "Saved totals don't move")

        model.discardEntryEdit()
        #expect(model.entryEditDayNutrition == nil)

        model.removeEditFood(entry.foods[1].id)
        model.removeEditFood(entry.foods[0].id)
        #expect(model.entryEdit?.draft.foods.count == 1, "The last food stays")
        try await model.saveEntryEdit()
        #expect(model.entryEdit?.hasChanges == false)
        #expect(try await store.entries(on: model.today).first?.foods.count == 1)
        #expect(model.dayNutrition[.energy].known < saved)
    }

    @Test("Renaming keeps unsaved amount changes; deleting ends the edit")
    func renameAndDelete() async throws {
        let (model, _, _) = try await seeded()
        await model.logSelectedMeal()
        let entry = try #require(model.entries.first)
        model.beginEditing(entry)
        model.setEditQuantity(10, for: entry.foods[0].id)
        try await model.renameEntry(entry, to: "  Big breakfast ")
        #expect(model.entries.first?.name == "Big breakfast")
        #expect(model.entries.first?.foods == entry.foods, "Amounts weren't saved by renaming")
        #expect(model.entryEdit?.draft.foods[0].quantity == 10)

        await model.deleteEntry(entry)
        #expect(model.entryEdit == nil)
    }
}
