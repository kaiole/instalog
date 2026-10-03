import Foundation
import Observation

/// A place entries can be logged into: a configured section, or the unsectioned daily log.
public struct Destination: Hashable, Sendable, Identifiable {
    public let section: RoutineSection?

    public init(section: RoutineSection?) { self.section = section }

    public var id: String { SectionKey.key(for: section?.id) }
    public var name: String { section?.name ?? "Daily log" }
    public var isUnsectioned: Bool { section == nil }
}

public extension LoggedEntry {
    /// Files the entry under a destination, keeping a name snapshot for history.
    mutating func assign(to destination: Destination) {
        sectionID = destination.section?.id
        sectionName = destination.section?.name
    }
}

public struct Toast: Identifiable, Sendable {
    public enum Undo: Sendable {
        case removeLogged(LoggedEntry, previousDestinationID: String, previousDraft: [UUID: Double]?, draftKey: String)
        case restoreDeleted(LoggedEntry)
    }

    public let id = UUID()
    public let message: String
    public let undo: Undo?

    public init(message: String, undo: Undo?) {
        self.message = message
        self.undo = undo
    }
}

/// A food the user logged recently, with the amount they used last time.
public struct RecentFood: Identifiable, Hashable, Sendable {
    public var food: FoodDefinition
    public var quantity: Double
    public var unit: MeasureUnit
    public var loggedOn: LogDate

    public var id: UUID { food.id }
}

public struct FoodSearchOutcome: Sendable {
    public var personalFoods: [FoodDefinition]
    public var catalogFoods: [CatalogFoodSummary]
    /// Set when the catalog failed, as distinct from returning no results.
    public var catalogError: String?
}

/// Observable state and actions for the routine-first logging experience.
///
/// Browsing (sections, meals, dates) never writes entries or changes totals. Every write goes
/// through `LoggingService` or a single atomic `PersonalStore.apply` batch, and local state only
/// changes after the write succeeds.
@MainActor
@Observable
public final class DiaryModel {
    public let store: any PersonalStore
    public let catalog: (any FoodCatalog)?
    public let calendar: Calendar
    private let clock: @Sendable () -> Date
    private let logging: LoggingService

    public private(set) var foods: [UUID: FoodDefinition] = [:]
    public private(set) var meals: [MealTemplate] = []
    public private(set) var sections: [RoutineSection] = []
    public private(set) var targets: [NutritionTarget] = []
    public private(set) var preferences = AppPreferences()

    public private(set) var today: LogDate
    public private(set) var viewedDate: LogDate
    public private(set) var entries: [LoggedEntry] = []
    public private(set) var isLoaded = false
    public private(set) var loadError: String?

    public private(set) var isLogging = false
    public var toast: Toast?
    public var errorMessage: String?

    private var destinationID: String = SectionKey.unsectioned
    private var mealSelections: [String: UUID] = [:]
    /// In-memory navigation per viewed day; today's is also persisted for same-day restarts.
    private var navigationByDate: [LogDate: (destinationID: String, selections: [String: UUID])] = [:]
    private var draftQuantities: [String: [UUID: Double]] = [:]

    public init(
        store: any PersonalStore, catalog: (any FoodCatalog)?, calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.catalog = catalog
        self.calendar = calendar
        self.clock = clock
        self.logging = LoggingService(store: store, now: clock)
        let start = LogDate(clock(), calendar: calendar)
        today = start
        viewedDate = start
    }

    // MARK: Loading

    public func load() async {
        do {
            let configuration = try await store.loadConfiguration()
            apply(configuration)
            today = LogDate(clock(), calendar: calendar)
            viewedDate = today
            entries = try await store.entries(on: today)
            restoreNavigation(configuration.navigation)
            isLoaded = true
            loadError = nil
        } catch {
            loadError = "Couldn’t open your data. \(error.localizedDescription)"
        }
    }

    private func apply(_ configuration: PersonalConfiguration) {
        foods = Dictionary(configuration.foods.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        meals = configuration.meals.sorted(by: MealSelection.libraryOrder)
        sections = configuration.sections.sorted { $0.sortOrder < $1.sortOrder }
        targets = configuration.targets
        preferences = configuration.preferences
    }

    private func restoreNavigation(_ memory: NavigationMemory?) {
        navigationByDate = [:]
        if let memory, memory.date == today {
            navigationByDate[today] = (SectionKey.key(for: memory.sectionID), memory.mealSelections)
        }
        showNavigation(for: today)
        draftQuantities = [:]
    }

    /// Restores remembered navigation for a day, or the new-day defaults: first section, and each
    /// section's first configured meal.
    private func showNavigation(for date: LogDate) {
        if let saved = navigationByDate[date] {
            destinationID = saved.destinationID
            mealSelections = saved.selections
        } else {
            destinationID = destinations.first?.id ?? SectionKey.unsectioned
            mealSelections = [:]
        }
    }

    // MARK: Derived state

    public var activeSections: [RoutineSection] { sections.filter { !$0.isArchived } }
    public var activeMeals: [MealTemplate] { meals.filter { !$0.isArchived } }
    public var hasSections: Bool { !activeSections.isEmpty }
    public var isViewingToday: Bool { viewedDate == today }

    /// Entries for the viewed day that don't belong to an active section.
    public var unsectionedEntries: [LoggedEntry] {
        let active = Set(activeSections.map(\.id))
        return entries.filter { entry in entry.sectionID.map { !active.contains($0) } ?? true }
    }

    /// Browsable destinations. With sections, the unsectioned log appears only when the day has
    /// entries outside every active section, so history from removed sections stays reachable.
    public var destinations: [Destination] {
        guard hasSections else { return [Destination(section: nil)] }
        var result = activeSections.map { Destination(section: $0) }
        if !unsectionedEntries.isEmpty { result.append(Destination(section: nil)) }
        return result
    }

    public var currentDestinationIndex: Int {
        destinations.firstIndex { $0.id == destinationID } ?? 0
    }

    public var currentDestination: Destination { destinations[currentDestinationIndex] }

    public var currentEntries: [LoggedEntry] { entries(in: currentDestination) }

    public func entries(in destination: Destination) -> [LoggedEntry] {
        guard let section = destination.section else { return unsectionedEntries }
        return entries.filter { $0.sectionID == section.id }
    }

    public var currentMeals: [MealTemplate] {
        MealSelection.meals(for: currentDestination.section, activeMeals: activeMeals)
    }

    public var currentUsesAllMeals: Bool {
        MealSelection.usesFallback(currentDestination.section, activeMeals: activeMeals)
    }

    public var selectedMeal: MealTemplate? {
        let options = currentMeals
        let selected = mealSelections[currentDestination.id]
        return options.first { $0.id == selected } ?? options.first
    }

    public var selectedMealIndex: Int? {
        guard let meal = selectedMeal else { return nil }
        return currentMeals.firstIndex(of: meal)
    }

    /// Draft edits belong to one day, one destination and one meal.
    private var draftKey: String { "\(viewedDate)|\(currentDestination.id)|\(selectedMeal?.id.uuidString ?? "")" }

    /// The selected meal at today's quantities. Not counted until logged.
    public var draftItems: [DraftItem] {
        guard let meal = selectedMeal else { return [] }
        let overrides = draftQuantities[draftKey] ?? [:]
        return DraftItem.items(for: meal, foods: foods).map { item in
            var copy = item
            if let quantity = overrides[item.id] { copy.quantity = quantity }
            return copy
        }
    }

    public var isDraftAdjusted: Bool { !(draftQuantities[draftKey] ?? [:]).isEmpty }

    /// True when any section has quantity edits that haven't been logged.
    public var hasUnsavedDraftEdits: Bool { draftQuantities.values.contains { !$0.isEmpty } }

    public var draftNutrition: NutritionSummary {
        (try? NutritionCalculator.summarize(draftItems.map(\.calculatorItem))) ?? NutritionSummary()
    }

    public var dayNutrition: NutritionSummary { NutritionCalculator.summarize(entries: entries) }

    /// Targets in effect on the viewed day, for totals and progress.
    public var effectiveTargets: [NutrientID: EffectiveTarget] { effectiveTargets(on: viewedDate) }

    public func effectiveTargets(on date: LogDate) -> [NutrientID: EffectiveTarget] {
        TargetResolver.effectiveTargets(on: date, targets: targets, showReferences: preferences.showReferenceValues)
    }

    /// The most recent entry of the selected meal in this destination, if any.
    public var previousLogOfSelectedMeal: LoggedEntry? {
        guard let meal = selectedMeal else { return nil }
        return currentEntries.last { $0.mealTemplateID == meal.id }
    }

    public func meal(id: UUID) -> MealTemplate? { meals.first { $0.id == id } }

    public func sections(containing mealID: UUID) -> [RoutineSection] {
        activeSections.filter { $0.mealIDs.contains(mealID) }
    }

    // MARK: Navigation (no side effects on logs or templates)

    public func selectDestination(at index: Int) {
        let all = destinations
        guard all.indices.contains(index) else { return }
        destinationID = all[index].id
        persistNavigation()
    }

    public func selectDestination(id: String) {
        guard destinations.contains(where: { $0.id == id }) else { return }
        destinationID = id
        persistNavigation()
    }

    /// Manual browsing wraps from last to first and back.
    public func browseDestinations(by step: Int) {
        let count = destinations.count
        guard count > 1 else { return }
        selectDestination(at: ProgressionPolicy.browse(from: currentDestinationIndex, by: step, sectionCount: count))
    }

    public func selectMeal(id: UUID) {
        guard currentMeals.contains(where: { $0.id == id }) else { return }
        mealSelections[currentDestination.id] = id
        persistNavigation()
    }

    public func browseMeals(by step: Int) {
        let options = currentMeals
        guard let index = selectedMealIndex else { return }
        let next = index + step
        guard options.indices.contains(next) else { return }
        selectMeal(id: options[next].id)
    }

    public func setDraftQuantity(_ quantity: Double, for itemID: UUID) {
        guard quantity.isFinite, let item = draftItems.first(where: { $0.id == itemID }) else { return }
        let value = QuantityInput.clamp(quantity, unit: item.unit)
        var overrides = draftQuantities[draftKey] ?? [:]
        if let template = item.templateQuantity, abs(template - value) < 1e-9 {
            overrides[itemID] = nil
        } else {
            overrides[itemID] = value
        }
        draftQuantities[draftKey] = overrides.isEmpty ? nil : overrides
    }

    public func resetDraft() {
        draftQuantities[draftKey] = nil
    }

    private func persistNavigation() {
        navigationByDate[viewedDate] = (currentDestination.id, mealSelections)
        guard isViewingToday else { return }
        let memory = NavigationMemory(
            date: today, sectionID: currentDestination.section?.id, mealSelections: mealSelections)
        let store = store
        Task { try? await store.apply([.putNavigation(memory)]) }
    }

    // MARK: Logging

    /// Logs the selected meal with its current quantities into the current destination.
    /// Returns false (and leaves everything as it was) when nothing was saved.
    @discardableResult
    public func logSelectedMeal() async -> Bool {
        guard !isLogging, let meal = selectedMeal else { return false }
        isLogging = true
        defer { isLogging = false }

        let destination = currentDestination
        let key = draftKey
        let previousDraft = draftQuantities[key]
        let request = LogRequest(
            name: meal.name, mealTemplateID: meal.id, items: draftItems, logDate: viewedDate,
            section: destination.section, path: .normal)
        do {
            let entry = try await logging.log(request)
            insertLocally(entry)
            draftQuantities[key] = nil

            var message = "Logged \(meal.name) to \(destination.name)"
            let currentIndex = destination.section.flatMap { section in activeSections.firstIndex { $0.id == section.id } }
            if preferences.autoProgression, activeSections.count > 1, let currentIndex,
                let nextIndex = ProgressionPolicy.sectionAfterLogging(
                    currentIndex: currentIndex, sectionCount: activeSections.count, path: .normal,
                    autoProgression: true)
            {
                if nextIndex != currentIndex {
                    destinationID = SectionKey.key(for: activeSections[nextIndex].id)
                    message += ". Now on \(activeSections[nextIndex].name)."
                } else {
                    message += ". That’s the last section."
                }
            }
            persistNavigation()
            toast = Toast(
                message: message,
                undo: .removeLogged(entry, previousDestinationID: destination.id, previousDraft: previousDraft, draftKey: key))
            return true
        } catch {
            errorMessage = "Nothing was logged. \(error.localizedDescription)"
            return false
        }
    }

    /// Commits an Add food composition into `destination` on `date`. Never auto-advances.
    /// When `saveAsMealNamed` is set, the composition also becomes a saved meal in the same transaction.
    @discardableResult
    public func logAdditional(
        name: String, items: [DraftItem], mealTemplateID: UUID?, destination: Destination, date: LogDate,
        saveAsMealNamed mealName: String? = nil
    ) async throws -> LoggedEntry {
        guard !isLogging else { throw LoggingBusyError() }
        isLogging = true
        defer { isLogging = false }

        var extra: [StoreOperation] = []
        var newMeal: MealTemplate?
        if let mealName {
            let meal = MealTemplate(
                name: mealName.trimmingCharacters(in: .whitespacesAndNewlines),
                items: items.filter { $0.quantity > 0 }.map {
                    MealTemplateItem(foodID: $0.food.id, defaultQuantity: $0.quantity, unit: $0.unit)
                },
                sortOrder: nextMealSortOrder, createdAt: clock())
            let knownFoods = foods.merging(items.map { ($0.food.id, $0.food) }, uniquingKeysWith: { $1 })
            try meal.validate(foods: knownFoods)
            extra.append(.putMeal(meal))
            newMeal = meal
        }
        let request = LogRequest(
            name: name, mealTemplateID: mealTemplateID ?? newMeal?.id, items: items, logDate: date,
            section: destination.section, path: .additional, additionalOperations: extra)
        let entry = try await logging.log(request)
        for item in items { foods[item.food.id] = item.food }
        if let newMeal { meals = (meals + [newMeal]).sorted(by: MealSelection.libraryOrder) }
        insertLocally(entry)
        toast = Toast(
            message: "Added \(entry.name) to \(destination.name)" + (newMeal != nil ? ", and saved it as a meal" : ""),
            undo: .removeLogged(entry, previousDestinationID: destinationID, previousDraft: nil, draftKey: ""))
        return entry
    }

    public func updateEntry(_ entry: LoggedEntry) async throws {
        let previous = entries.first { $0.id == entry.id }
        let saved = try await logging.update(entry)
        replaceLocally(saved)
        if let previous, previous.sectionID != saved.sectionID {
            toast = Toast(message: "Moved \(saved.name) to \(destinationName(for: saved))", undo: nil)
        }
    }

    /// Moves an entry to another destination without changing its foods, nutrition or time.
    public func moveEntry(_ entry: LoggedEntry, to destination: Destination) async throws {
        var moved = entry
        moved.assign(to: destination)
        let saved = try await logging.update(moved)
        replaceLocally(saved)
        toast = Toast(message: "Moved \(entry.name) to \(destination.name)", undo: nil)
    }

    public func deleteEntry(_ entry: LoggedEntry) async {
        do {
            try await logging.delete(entry)
            entries.removeAll { $0.id == entry.id }
            toast = Toast(
                message: "Deleted \(entry.name) from \(destinationName(for: entry))", undo: .restoreDeleted(entry))
        } catch {
            errorMessage = "Couldn’t delete \(entry.name). \(error.localizedDescription)"
        }
    }

    public func undo(_ toast: Toast) async {
        guard let undo = toast.undo else { return }
        if self.toast?.id == toast.id { self.toast = nil }
        do {
            switch undo {
            case .removeLogged(let entry, let previousDestinationID, let previousDraft, let key):
                try await logging.delete(entry)
                entries.removeAll { $0.id == entry.id }
                if entry.logDate == viewedDate, destinations.contains(where: { $0.id == previousDestinationID }) {
                    destinationID = previousDestinationID
                    if let previousDraft, !key.isEmpty { draftQuantities[key] = previousDraft }
                    persistNavigation()
                }
            case .restoreDeleted(let entry):
                try await logging.restore(entry)
                insertLocally(entry)
            }
        } catch {
            errorMessage = "Couldn’t undo. \(error.localizedDescription)"
        }
    }

    public func destinationName(for entry: LoggedEntry) -> String {
        if let id = entry.sectionID, let section = sections.first(where: { $0.id == id }) {
            return section.isArchived ? "\(section.name) (removed)" : section.name
        }
        return entry.sectionName ?? Destination(section: nil).name
    }

    private func insertLocally(_ entry: LoggedEntry) {
        guard entry.logDate == viewedDate else { return }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { ($0.recordedAt, $0.id.uuidString) < ($1.recordedAt, $1.id.uuidString) }
    }

    private func replaceLocally(_ entry: LoggedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
    }

    // MARK: Dates

    public var canShowNextDay: Bool { viewedDate < today }

    /// Days between `first` and `last` (inclusive) that have entries, for marking a calendar.
    /// Empty when the store can't be read; the marks are a convenience, not data.
    public func daysWithEntries(from first: LogDate, through last: LogDate) async -> Set<LogDate> {
        (try? await store.datesWithEntries(from: first, through: last)) ?? []
    }

    /// Shows the day before (-1) or after (+1) the viewed one. Never moves past today.
    public func showAdjacentDay(_ step: Int) async {
        await changeDate(to: viewedDate.adding(days: step, calendar: calendar))
    }

    public func changeDate(to date: LogDate) async {
        guard date != viewedDate, date <= today else { return }
        do {
            let loaded = try await store.entries(on: date)
            navigationByDate[viewedDate] = (currentDestination.id, mealSelections)
            viewedDate = date
            entries = loaded
            showNavigation(for: date)
        } catch {
            errorMessage = "Couldn’t load that day. \(error.localizedDescription)"
        }
    }

    /// Call when the app becomes active or the calendar day changes. Moves an idle "today" view
    /// to the new day with fresh defaults; a view with unsaved edits keeps its original date.
    public func refreshForCurrentDate(isIdle: Bool) async {
        let now = LogDate(clock(), calendar: calendar)
        guard now != today else { return }
        let wasViewingToday = isViewingToday
        today = now
        guard wasViewingToday, isIdle, !hasUnsavedDraftEdits else { return }
        do {
            entries = try await store.entries(on: now)
            viewedDate = now
            draftQuantities = [:]
            showNavigation(for: now)
        } catch {
            errorMessage = "Couldn’t load today. \(error.localizedDescription)"
        }
    }

    // MARK: Foods and search

    public var customFoods: [FoodDefinition] {
        foods.values.filter { $0.source == .custom && !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Foods from the most recent entries, newest first, each once, with the amount last used.
    public func recentFoods(limit: Int = 10) async -> [RecentFood] {
        guard let recent = try? await store.recentEntries(limit: 60) else { return [] }
        var seen = Set<String>()
        var result: [RecentFood] = []
        for entry in recent {
            for snapshot in entry.foods.reversed() {
                guard let key = snapshot.catalogKey ?? snapshot.foodID?.uuidString, seen.insert(key).inserted,
                    let food = resolve(snapshot)
                else { continue }
                result.append(RecentFood(food: food, quantity: snapshot.quantity, unit: snapshot.unit, loggedOn: entry.logDate))
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// The current personal food for a logged snapshot. Custom foods that were deleted are skipped.
    private func resolve(_ snapshot: LoggedFoodSnapshot) -> FoodDefinition? {
        if let id = snapshot.foodID, let food = foods[id] { return food.isArchived ? nil : food }
        if let key = snapshot.catalogKey {
            return foods.values.first { $0.catalogKey == key } ?? snapshot.asFoodDefinition
        }
        return nil
    }

    public func searchFoods(_ query: String) async -> FoodSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.lowercased().split(separator: " ")
        let personal = foods.values
            .filter { food in
                food.source == .custom && !food.isArchived
                    && !words.isEmpty
                    && words.allSatisfy { word in
                        food.name.lowercased().contains(word) || (food.brand?.lowercased().contains(word) ?? false)
                    }
            }
            .sorted { $0.name < $1.name }
        guard !trimmed.isEmpty else { return FoodSearchOutcome(personalFoods: [], catalogFoods: [], catalogError: nil) }
        guard let catalog else {
            return FoodSearchOutcome(personalFoods: personal, catalogFoods: [], catalogError: "Food database unavailable")
        }
        do {
            let results = try await catalog.search(trimmed, limit: 60)
            return FoodSearchOutcome(personalFoods: personal, catalogFoods: results, catalogError: nil)
        } catch {
            return FoodSearchOutcome(
                personalFoods: personal, catalogFoods: [], catalogError: error.localizedDescription)
        }
    }

    /// A personal food for a catalog record, reusing an existing copy so templates share it.
    /// New copies are persisted when first logged or saved in a meal.
    public func food(forCatalogID id: String) async throws -> FoodDefinition {
        guard let catalog else { throw CatalogError.unavailable("no catalog") }
        guard let fresh = try await catalog.food(id: id) else { throw CatalogError.queryFailed("food \(id) not found") }
        if let existing = foods.values.first(where: { $0.catalogKey == fresh.catalogKey }) { return existing }
        return fresh
    }

    /// Creates or updates a custom food. Saved meals that use it must still be valid afterwards.
    public func saveCustomFood(_ food: FoodDefinition) async throws {
        try FoodDefinition.validateCustom(name: food.name, nutrition: food.nutrition)
        var saved = food
        saved.updatedAt = clock()
        if foods[food.id] != nil {
            let updatedFoods = foods.merging([(saved.id, saved)], uniquingKeysWith: { $1 })
            for meal in meals(using: food.id) { try meal.validate(foods: updatedFoods) }
        }
        try await store.apply([.putFood(saved)])
        foods[saved.id] = saved
    }

    /// Active saved meals that include the food.
    public func meals(using foodID: UUID) -> [MealTemplate] {
        activeMeals.filter { meal in meal.items.contains { $0.foodID == foodID } }
    }

    /// Hides a custom food from search and lists. Refused while an active saved meal uses it;
    /// logged entries keep their own snapshots either way.
    public func archiveCustomFood(id: UUID) async throws {
        guard var food = foods[id], food.source == .custom, !food.isArchived else { return }
        let using = meals(using: id)
        guard using.isEmpty else { throw FoodInUseError(mealNames: using.map(\.name)) }
        food.archivedAt = clock()
        food.updatedAt = clock()
        try await store.apply([.putFood(food)])
        foods[id] = food
    }

    // MARK: Saved meals

    private var nextMealSortOrder: Int { (meals.map(\.sortOrder).max() ?? -1) + 1 }

    /// Creates or updates a saved meal. Only future defaults change; logged entries keep snapshots.
    public func saveMeal(_ meal: MealTemplate, foods newFoods: [FoodDefinition]) async throws {
        var saved = meal
        let knownFoods = foods.merging(newFoods.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        saved.name = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meals.contains(where: { $0.id == meal.id }) {
            saved.sortOrder = nextMealSortOrder
            saved.createdAt = clock()
        }
        saved.updatedAt = clock()
        try saved.validate(foods: knownFoods)
        let usedFoods = newFoods.filter { food in saved.items.contains { $0.foodID == food.id } }
        try await store.apply(usedFoods.map(StoreOperation.putFood) + [.putMeal(saved)])
        for food in usedFoods { foods[food.id] = food }
        if let index = meals.firstIndex(where: { $0.id == saved.id }) {
            meals[index] = saved
        } else {
            meals.append(saved)
        }
        meals.sort(by: MealSelection.libraryOrder)
    }

    /// Removes a meal from future selection and every section; logged instances are untouched.
    public func archiveMeal(id: UUID) async throws {
        guard var meal = meals.first(where: { $0.id == id }) else { return }
        meal.archivedAt = clock()
        var changedSections: [RoutineSection] = []
        for var section in sections where section.mealIDs.contains(id) {
            section.mealIDs.removeAll { $0 == id }
            section.updatedAt = clock()
            changedSections.append(section)
        }
        try await store.apply([.putMeal(meal)] + changedSections.map(StoreOperation.putSection))
        meals = meals.map { $0.id == id ? meal : $0 }
        replaceSections(changedSections)
        draftQuantities = draftQuantities.filter { !$0.key.hasSuffix(id.uuidString) }
    }

    // MARK: Sections

    public func addSection(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SectionNameError() }
        let section = RoutineSection(
            name: trimmed, sortOrder: (sections.map(\.sortOrder).max() ?? -1) + 1, createdAt: clock())
        try await store.apply([.putSection(section)])
        let hadSections = hasSections
        sections.append(section)
        if !hadSections { destinationID = SectionKey.key(for: section.id) }
    }

    public func renameSection(id: UUID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var section = sections.first(where: { $0.id == id }) else {
            throw SectionNameError()
        }
        guard section.name != trimmed else { return }
        section.name = trimmed
        section.updatedAt = clock()
        try await saveSections([section])
    }

    /// Reorders active sections. The new order drives browsing, new-day start and progression.
    public func moveSections(from source: IndexSet, to destination: Int) async throws {
        try await saveOrder(of: activeSections.moving(fromOffsets: source, toOffset: destination))
    }

    private func saveOrder(of ordered: [RoutineSection]) async throws {
        let archived = sections.filter(\.isArchived)
        let renumbered = (ordered + archived).enumerated().map { index, section in
            var copy = section
            copy.sortOrder = index
            return copy
        }
        try await saveSections(renumbered)
    }

    /// Archives a section. Its entries keep their section ID and name snapshot.
    public func removeSection(id: UUID) async throws {
        guard var section = sections.first(where: { $0.id == id }) else { return }
        let wasCurrent = currentDestination.section?.id == id
        section.archivedAt = clock()
        section.updatedAt = clock()
        try await saveSections([section])
        if wasCurrent { destinationID = destinations.first?.id ?? SectionKey.unsectioned }
    }

    public func setMeals(_ mealIDs: [UUID], forSection id: UUID) async throws {
        guard var section = sections.first(where: { $0.id == id }) else { return }
        var seen = Set<UUID>()
        section.mealIDs = mealIDs.filter { seen.insert($0).inserted }
        section.updatedAt = clock()
        try await saveSections([section])
    }

    private func saveSections(_ changed: [RoutineSection]) async throws {
        try await store.apply(changed.map(StoreOperation.putSection))
        replaceSections(changed)
        persistNavigation()
    }

    private func replaceSections(_ changed: [RoutineSection]) {
        for section in changed {
            if let index = sections.firstIndex(where: { $0.id == section.id }) {
                sections[index] = section
            } else {
                sections.append(section)
            }
        }
        sections.sort { $0.sortOrder < $1.sortOrder }
    }

    // MARK: Preferences and targets

    public func setAutoProgression(_ enabled: Bool) async throws {
        var updated = preferences
        updated.autoProgression = enabled
        try await savePreferences(updated)
    }

    public func setSummaryNutrients(_ nutrients: [NutrientID]) async throws {
        guard !nutrients.isEmpty, nutrients.count <= AppPreferences.maxSummaryNutrients else { return }
        var updated = preferences
        updated.summaryNutrients = nutrients
        try await savePreferences(updated)
    }

    public func setShowReferenceValues(_ enabled: Bool) async throws {
        var updated = preferences
        updated.showReferenceValues = enabled
        try await savePreferences(updated)
    }

    private func savePreferences(_ updated: AppPreferences) async throws {
        try await store.apply([.putPreferences(updated)])
        preferences = updated
    }

    /// The user's own target record in effect today, if any.
    public func userTarget(for nutrient: NutrientID, on date: LogDate? = nil) -> NutritionTarget? {
        let day = date ?? today
        return targets.filter { $0.nutrientID == nutrient && $0.effectiveDate <= day }
            .max { $0.effectiveDate < $1.effectiveDate }
    }

    /// Sets a personal target from today onward. Earlier days keep the target they had; a
    /// nutrient's first-ever record applies to all days, since nothing was in effect before.
    public func setTarget(_ nutrient: NutrientID, amount: Double, kind: TargetKind) async throws {
        guard let definition = NutrientRegistry.definition(for: nutrient) else { return }
        guard amount.isFinite, amount >= 0, amount <= NutritionTarget.maximumAmount else { throw TargetValueError() }
        try await saveTarget(
            nutrient, kind: kind, amount: amount, unit: definition.unit, form: definition.form, enabled: true,
            source: .user)
    }

    /// Hides any target or reference for the nutrient from today onward.
    public func disableTarget(_ nutrient: NutrientID) async throws {
        guard let definition = NutrientRegistry.definition(for: nutrient) else { return }
        let current = effectiveTargets(on: today)[nutrient]
        try await saveTarget(
            nutrient, kind: current?.kind ?? .target, amount: current?.amount ?? 0, unit: definition.unit,
            form: definition.form, enabled: false, source: .user)
    }

    /// Goes back to the FDA reference value from today onward.
    public func useReferenceValue(_ nutrient: NutrientID) async throws {
        guard let reference = FDADailyValues.value(for: nutrient) else { return }
        try await saveTarget(
            nutrient, kind: reference.kind, amount: reference.amount, unit: reference.unit, form: reference.form,
            enabled: true, source: .referenceTable(name: FDADailyValues.sourceName, version: FDADailyValues.version))
    }

    private func saveTarget(
        _ nutrient: NutrientID, kind: TargetKind, amount: Double, unit: NutrientUnit, form: String?, enabled: Bool,
        source: TargetSource
    ) async throws {
        let hasHistory = targets.contains { $0.nutrientID == nutrient }
        let effective = hasHistory ? today : .beginning
        let sameDay = targets.first { $0.nutrientID == nutrient && $0.effectiveDate == effective }
        let target = NutritionTarget(
            id: sameDay?.id ?? UUID(), nutrientID: nutrient, kind: kind, amount: amount, unit: unit, form: form,
            effectiveDate: effective, enabled: enabled, source: source)
        try await store.apply([.putTarget(target)])
        targets.removeAll { $0.id == target.id }
        targets.append(target)
    }

    // MARK: Export and import

    public func exportData() async throws -> Data {
        try ExportService.encode(try await fullDataSet(), exportedAt: clock())
    }

    private func fullDataSet() async throws -> PersonalDataSet {
        let configuration = try await store.loadConfiguration()
        return PersonalDataSet(
            foods: configuration.foods, meals: configuration.meals, sections: configuration.sections,
            entries: try await store.allEntries(), targets: configuration.targets,
            preferences: configuration.preferences)
    }

    /// Writes a recovery export of current data, then atomically replaces everything with `data`.
    /// Returns the recovery file location.
    @discardableResult
    public func replaceAllData(with data: PersonalDataSet, recoveryDirectory: URL) async throws -> URL {
        try ExportService.validate(data)
        let recovery = try await exportData()
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let stamp = Int(clock().timeIntervalSince1970)
        let recoveryURL = recoveryDirectory.appendingPathComponent("instalog-recovery-\(stamp).json")
        try recovery.write(to: recoveryURL, options: [.atomic, .completeFileProtection])
        try await store.replaceAll(with: data)
        await load()
        return recoveryURL
    }

    /// Adds a sample routine from real catalog foods. Only offered while the library is empty.
    public func loadDemoRoutine() async throws {
        guard let catalog, activeMeals.isEmpty else { return }
        let routine = try await DemoRoutine.build(catalog: catalog, now: clock(), startingSortOrder: nextMealSortOrder)
        var operations = routine.foods.map(StoreOperation.putFood)
        operations += routine.meals.map(StoreOperation.putMeal)
        if !hasSections { operations += routine.sections.map(StoreOperation.putSection) }
        for target in routine.targets where !targets.contains(where: { $0.nutrientID == target.nutrientID }) {
            operations.append(.putTarget(target))
        }
        try await store.apply(operations)
        await load()
    }
}

public struct LoggingBusyError: Error {}
public struct SectionNameError: Error {}
public struct TargetValueError: Error {}
public struct FoodInUseError: Error, Equatable {
    public let mealNames: [String]
}
