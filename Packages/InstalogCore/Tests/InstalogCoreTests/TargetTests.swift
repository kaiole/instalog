import Foundation
import Testing
@testable import InstalogCore

@Suite("Targets and references")
struct TargetTests {
    private let day = LogDate(year: 2026, month: 10, day: 1)

    @Test("FDA references apply when shown and no personal record exists")
    func referencesShown() {
        let targets = TargetResolver.effectiveTargets(on: day, targets: [], showReferences: true)
        #expect(targets[.magnesium]?.amount == 420)
        #expect(targets[.magnesium]?.isReference == true)
        #expect(targets[.sodium]?.kind == .limit)
        #expect(targets[.energy] == nil, "Calorie goals are user-entered, never imported")
        #expect(targets[.protein] == nil)
        #expect(TargetResolver.effectiveTargets(on: day, targets: [], showReferences: false).isEmpty)
    }

    @Test("A disabled personal record hides the reference; it is not a target of zero")
    func disabledHidesReference() {
        let disabled = NutritionTarget(
            nutrientID: .magnesium, kind: .target, amount: 0, unit: .milligram, effectiveDate: .beginning, enabled: false)
        let targets = TargetResolver.effectiveTargets(on: day, targets: [disabled], showReferences: true)
        #expect(targets[.magnesium] == nil)
    }

    @Test("AT-34: historical days keep the target that was effective then")
    func effectiveDates() {
        let original = NutritionTarget(
            nutrientID: .energy, kind: .target, amount: 2200, unit: .kilocalorie, effectiveDate: .beginning)
        let changed = NutritionTarget(
            nutrientID: .energy, kind: .target, amount: 2000, unit: .kilocalorie, effectiveDate: day)
        let yesterday = day.adding(days: -1)
        #expect(TargetResolver.effectiveTargets(on: yesterday, targets: [original, changed], showReferences: false)[.energy]?.amount == 2200)
        #expect(TargetResolver.effectiveTargets(on: day, targets: [original, changed], showReferences: false)[.energy]?.amount == 2000)
    }

    @Test("Niacin equivalents are not compared with preformed niacin")
    func incompatibleForm() {
        let reference = TargetResolver.effectiveTargets(on: day, targets: [], showReferences: true)[.niacin]
        let comparison = TargetResolver.compare(NutrientTotal(known: 10, reportingFoods: 1, totalFoods: 1), with: reference)
        #expect(!comparison.isComparable)
        #expect(comparison.fraction == nil)
    }

    @Test("Compatible forms and mass units compare")
    func compatibleComparison() {
        let reference = TargetResolver.effectiveTargets(on: day, targets: [], showReferences: true)[.vitaminA]
        let comparison = TargetResolver.compare(NutrientTotal(known: 450, reportingFoods: 2, totalFoods: 2), with: reference)
        #expect(comparison.isComparable)
        #expect(comparison.fraction!.isClose(to: 0.5))
        #expect(!comparison.isQualified)
    }

    @Test("Partial totals stay qualified")
    func partialQualified() {
        let reference = TargetResolver.effectiveTargets(on: day, targets: [], showReferences: true)[.magnesium]
        let comparison = TargetResolver.compare(NutrientTotal(known: 20, reportingFoods: 1, totalFoods: 2), with: reference)
        #expect(comparison.isQualified)
        #expect(comparison.fraction != nil)
    }

    @Test("A zero target never divides by zero; unknown totals have no progress")
    func noDivisionByZero() {
        let zero = EffectiveTarget(
            nutrientID: .caffeine, kind: .limit, amount: 0, unit: .milligram, form: nil, source: .user, note: nil)
        #expect(TargetResolver.compare(NutrientTotal(known: 50, reportingFoods: 1, totalFoods: 1), with: zero).fraction == nil)
        let unknown = TargetResolver.compare(
            NutrientTotal(known: 0, reportingFoods: 0, totalFoods: 3),
            with: TargetResolver.effectiveTargets(on: day, targets: [], showReferences: true)[.magnesium])
        #expect(unknown.fraction == nil)
    }

    @Test("Invalid target values are rejected")
    func invalidValues() {
        #expect(!NutritionTarget(nutrientID: .protein, kind: .target, amount: -1, unit: .gram, effectiveDate: day).isValid)
        #expect(!NutritionTarget(nutrientID: .protein, kind: .target, amount: .nan, unit: .gram, effectiveDate: day).isValid)
    }
}

@MainActor
@Suite("Resetting micronutrient targets")
struct TargetResetTests {
    let clock = TestClock()

    private func model() async throws -> DiaryModel {
        await Scenario.model(store: try SQLitePersonalStore(url: nil), clock: clock)
    }

    @Test("Counts only nutrients that differ from their FDA Daily Value")
    func customCount() async throws {
        let model = try await model()
        #expect(model.customMicronutrientTargets.isEmpty)
        #expect(!model.canResetMicronutrientTargets)

        try await model.setMacroTargets(MacroBalance(energy: 2000, protein: 150, carbohydrate: 237.5, fat: 50))
        try await model.setTarget(.iron, amount: 8, kind: .target)
        try await model.disableTarget(.vitaminC)
        try await model.setTarget(.caffeine, amount: 400, kind: .limit)
        try await model.setTarget(.zinc, amount: 11, kind: .reference)
        #expect(model.customMicronutrientTargets == [.iron, .vitaminC].sorted { $0.rawValue < $1.rawValue })
        #expect(model.canResetMicronutrientTargets)
    }

    @Test("Reset restores FDA values, re-enables nutrients, and leaves calories, macros and other limits alone")
    func reset() async throws {
        let model = try await model()
        try await model.setMacroTargets(MacroBalance(energy: 2000, protein: 150, carbohydrate: 237.5, fat: 50))
        try await model.setTarget(.iron, amount: 8, kind: .target)
        try await model.disableTarget(.vitaminC)
        try await model.setTarget(.caffeine, amount: 400, kind: .limit)
        let yesterday = model.today.adding(days: -1)
        let before = model.effectiveTargets(on: yesterday)
        clock.advance(seconds: 86_400)
        await model.tick()

        #expect(try await model.resetMicronutrientTargets().count == 2)
        let now = model.effectiveTargets(on: model.today)
        #expect(now[.iron]?.amount == 18)
        #expect(now[.iron]?.isReference == true)
        #expect(now[.vitaminC]?.amount == 90)
        #expect(now[.caffeine]?.amount == 400, "Limits without a Daily Value are the user's own; reset keeps them")
        #expect(now[.energy]?.amount == 2000)
        #expect(now[.protein]?.amount == 150)
        #expect(model.effectiveTargets(on: yesterday) == before, "Earlier days keep their targets")
        #expect(model.customMicronutrientTargets.isEmpty)
        #expect(try await model.resetMicronutrientTargets().count == 0)
    }

    @Test("Reset turns FDA values back on")
    func showsReferences() async throws {
        let model = try await model()
        try await model.setShowReferenceValues(false)
        #expect(model.canResetMicronutrientTargets)
        #expect(try await model.resetMicronutrientTargets().count == 0)
        #expect(model.preferences.showReferenceValues)
        #expect(!model.canResetMicronutrientTargets)
    }

    @Test("Undo puts the custom targets back")
    func undo() async throws {
        let model = try await model()
        try await model.setTarget(.iron, amount: 8, kind: .target)
        try await model.disableTarget(.vitaminC)
        try await model.setShowReferenceValues(false)
        let reset = try await model.resetMicronutrientTargets()
        try await model.undoTargetReset(reset)
        let now = model.effectiveTargets(on: model.today)
        #expect(now[.iron]?.amount == 8)
        #expect(model.userTarget(for: .vitaminC)?.enabled == false)
        #expect(!model.preferences.showReferenceValues)
        #expect(model.customMicronutrientTargets == [.iron, .vitaminC].sorted { $0.rawValue < $1.rawValue })
    }

    @Test("Reset commits in one batch")
    func oneBatch() async throws {
        let store = ControllableStore(inner: try SQLitePersonalStore(url: nil))
        let model = await Scenario.model(store: store, clock: clock)
        try await model.setTarget(.iron, amount: 8, kind: .target)
        try await model.setTarget(.zinc, amount: 5, kind: .target)
        let writes = await store.applyCount
        try await model.resetMicronutrientTargets()
        #expect(await store.applyCount == writes + 1)
    }
}
