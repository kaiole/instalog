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
        case unskip(OccurrenceKey)
    }

    public let id = UUID()
    public let message: String
    public let undo: Undo?

    public init(message: String, undo: Undo?) {
        self.message = message
        self.undo = undo
    }
}

/// A logged entry being edited inline: what's saved, and the unsaved preview.
public struct EntryEdit: Equatable, Sendable {
    public var original: LoggedEntry
    public var draft: LoggedEntry

    public init(original: LoggedEntry) {
        self.original = original
        draft = original
    }

    public var hasChanges: Bool { draft.foods != original.foods || draft.name != original.name }
}

/// A food the user logged recently, with the amount they used last time.
public struct RecentFood: Identifiable, Hashable, Sendable {
    public var food: FoodDefinition
    public var quantity: Double
    public var unit: MeasureUnit
    public var loggedOn: LogDate

    public var id: UUID { food.id }
}

/// What a micronutrient reset replaced, so it can be undone.
public struct TargetReset: Sendable {
    public var nutrients: [NutrientID]
    /// The records in effect before the reset, for the nutrients it changed.
    public var previous: [NutritionTarget]
    public var previousShowReferences: Bool

    public var count: Int { nutrients.count }
}

/// One section of the day overview: what's logged there and what's scheduled to come.
public struct SectionOverview: Identifiable, Sendable {
    public var destination: Destination
    public var entries: [LoggedEntry]
    public var scheduled: [ScheduledOccurrence]
    public var skipped: [ScheduledOccurrence]
    public var loggedEnergy: Double
    public var scheduledEnergy: Double

    public var id: String { destination.id }
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
    public private(set) var schedules: [MealSchedule] = []

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

    /// The logged entry being edited inline, if any. Changes stay a preview until saved.
    public private(set) var entryEdit: EntryEdit?

    /// What happened to scheduled occurrences on the viewed day that were already logged or skipped.
    private var outcomesOnViewedDate: [OccurrenceKey: OccurrenceOutcome] = [:]
    /// The time upcoming scheduled meals are judged against; advanced by `tick()`.
    public private(set) var lastTick: Date
    /// Changes whenever schedules or their occurrences change, so notifications can be refreshed.
    public private(set) var scheduleRevision = 0
    private var isMaterializing = false

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
        lastTick = clock()
    }

    // MARK: Loading

    public func load() async {
        do {
            let configuration = try await store.loadConfiguration()
            apply(configuration)
            entryEdit = nil
            today = LogDate(clock(), calendar: calendar)
            viewedDate = today
            entries = try await store.entries(on: today)
            outcomesOnViewedDate = try await occurrenceOutcomes(on: today)
            lastTick = clock()
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
        schedules = configuration.schedules
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
    /// A day that hasn't happened yet. Logging there plans ahead.
    public var isViewingFuture: Bool { viewedDate > today }

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

    /// The day's totals as they'd be if the entry being edited were saved; nil without unsaved edits.
    public var entryEditDayNutrition: NutritionSummary? {
        guard let edit = entryEdit, edit.hasChanges else { return nil }
        return NutritionCalculator.summarize(entries: entries.map { $0.id == edit.draft.id ? edit.draft : $0 })
    }

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
        var moved = entries.first { $0.id == entry.id } ?? entry
        moved.assign(to: destination)
        let saved = try await logging.update(moved)
        replaceLocally(saved)
        if entryEdit?.original.id == saved.id { entryEdit = nil }
        toast = Toast(message: "Moved \(entry.name) to \(destination.name)", undo: nil)
    }

    public func deleteEntry(_ entry: LoggedEntry) async {
        do {
            try await logging.delete(entry)
            entries.removeAll { $0.id == entry.id }
            if entryEdit?.original.id == entry.id { entryEdit = nil }
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
                if let occurrence = entry.scheduleOccurrence {
                    try await removeScheduledLog(entry, occurrence: occurrence)
                } else {
                    try await logging.delete(entry)
                }
                entries.removeAll { $0.id == entry.id }
                if entry.logDate == viewedDate, destinations.contains(where: { $0.id == previousDestinationID }) {
                    destinationID = previousDestinationID
                    if let previousDraft, !key.isEmpty { draftQuantities[key] = previousDraft }
                    persistNavigation()
                }
            case .restoreDeleted(let entry):
                try await logging.restore(entry)
                insertLocally(entry)
            case .unskip(let key):
                try await unskip(key)
            }
        } catch {
            errorMessage = "Couldn’t undo. \(error.localizedDescription)"
        }
    }

    // MARK: Editing a logged entry inline

    /// Starts editing a logged entry, dropping any other entry's unsaved changes.
    public func beginEditing(_ entry: LoggedEntry) {
        guard entryEdit?.original.id != entry.id else { return }
        entryEdit = EntryEdit(original: entry)
    }

    /// Stops editing. Unsaved changes are dropped.
    public func endEditing() {
        entryEdit = nil
    }

    public func setEditQuantity(_ quantity: Double, for foodID: UUID) {
        guard quantity.isFinite, let index = entryEdit?.draft.foods.firstIndex(where: { $0.id == foodID }),
            let unit = entryEdit?.draft.foods[index].unit
        else { return }
        entryEdit?.draft.foods[index].quantity = QuantityInput.clamp(quantity, unit: unit)
    }

    /// Removes a food from the edit. The last food stays; delete the entry instead.
    public func removeEditFood(_ foodID: UUID) {
        guard let edit = entryEdit, edit.draft.foods.count > 1 else { return }
        entryEdit?.draft.foods.removeAll { $0.id == foodID }
    }

    /// Puts the edit back to what's saved.
    public func discardEntryEdit() {
        guard let edit = entryEdit else { return }
        entryEdit = EntryEdit(original: edit.original)
    }

    /// Saves the edit. The entry stays open, now matching what's saved.
    public func saveEntryEdit() async throws {
        guard let edit = entryEdit, edit.hasChanges else { return }
        try await updateEntry(edit.draft)
        if let saved = entries.first(where: { $0.id == edit.draft.id }) {
            entryEdit = EntryEdit(original: saved)
        }
    }

    /// Renames a logged entry right away, keeping any unsaved amount changes in the edit.
    public func renameEntry(_ entry: LoggedEntry, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        var renamed = entries.first { $0.id == entry.id } ?? entry
        renamed.name = trimmed
        let saved = try await logging.update(renamed)
        replaceLocally(saved)
        if entryEdit?.original.id == saved.id {
            entryEdit?.original = saved
            entryEdit?.draft.name = saved.name
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

    /// Days between `first` and `last` (inclusive) that have entries, for marking a calendar.
    /// Empty when the store can't be read; the marks are a convenience, not data.
    public func daysWithEntries(from first: LogDate, through last: LogDate) async -> Set<LogDate> {
        (try? await store.datesWithEntries(from: first, through: last)) ?? []
    }

    /// Shows the day before (-1) or after (+1) the viewed one.
    public func showAdjacentDay(_ step: Int) async {
        await changeDate(to: viewedDate.adding(days: step, calendar: calendar))
    }

    /// Opens any day, past or future. Future days are for planning; their entries are ordinary.
    public func changeDate(to date: LogDate) async {
        guard date != viewedDate else { return }
        do {
            let loaded = try await store.entries(on: date)
            outcomesOnViewedDate = try await occurrenceOutcomes(on: date)
            entryEdit = nil
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
        guard wasViewingToday, isIdle, !hasUnsavedDraftEdits, entryEdit?.hasChanges != true else { return }
        do {
            entries = try await store.entries(on: now)
            outcomesOnViewedDate = try await occurrenceOutcomes(on: now)
            entryEdit = nil
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
        await materializeDueOccurrences()
        meal.archivedAt = clock()
        var changedSections: [RoutineSection] = []
        for var section in sections where section.mealIDs.contains(id) {
            section.mealIDs.removeAll { $0 == id }
            section.updatedAt = clock()
            changedSections.append(section)
        }
        let stopped = archivedSchedules { $0.mealTemplateID == id }
        try await store.apply(
            [.putMeal(meal)] + changedSections.map(StoreOperation.putSection) + stopped.map(StoreOperation.putSchedule))
        meals = meals.map { $0.id == id ? meal : $0 }
        replaceSections(changedSections)
        replaceSchedules(stopped)
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
        await materializeDueOccurrences()
        let wasCurrent = currentDestination.section?.id == id
        section.archivedAt = clock()
        section.updatedAt = clock()
        let stopped = archivedSchedules { $0.sectionID == id }
        try await saveSections([section], with: stopped.map(StoreOperation.putSchedule))
        replaceSchedules(stopped)
        if wasCurrent { destinationID = destinations.first?.id ?? SectionKey.unsectioned }
    }

    public func setMeals(_ mealIDs: [UUID], forSection id: UUID) async throws {
        guard var section = sections.first(where: { $0.id == id }) else { return }
        var seen = Set<UUID>()
        section.mealIDs = mealIDs.filter { seen.insert($0).inserted }
        section.updatedAt = clock()
        try await saveSections([section])
    }

    private func saveSections(_ changed: [RoutineSection], with extra: [StoreOperation] = []) async throws {
        try await store.apply(changed.map(StoreOperation.putSection) + extra)
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

    /// The calorie and macro targets in effect on a day, for checking that they add up.
    public func macroBalance(on date: LogDate? = nil) -> MacroBalance {
        MacroBalance(targets: effectiveTargets(on: date ?? today))
    }

    /// Saves calories and macros together from today onward. A nil value turns that target off.
    /// Refuses targets that don't add up (see `MacroBalance.isConsistent`).
    public func setMacroTargets(_ balance: MacroBalance) async throws {
        guard balance.isConsistent else { throw MacroBalanceError(difference: balance.macroKcal - (balance.energy ?? 0)) }
        let current = effectiveTargets(on: today)
        var records: [NutritionTarget] = []
        for id in [NutrientID.energy] + MacroBalance.macros {
            guard let definition = NutrientRegistry.definition(for: id) else { continue }
            let existing = current[id]
            if let amount = balance[id] {
                guard amount.isFinite, amount >= 0, amount <= NutritionTarget.maximumAmount else { throw TargetValueError() }
                if let existing, existing.amount == amount { continue }
                let kind = existing.map { $0.kind == .limit ? TargetKind.limit : .target } ?? .target
                records.append(targetRecord(
                    id, kind: kind, amount: amount, unit: definition.unit, form: definition.form, enabled: true,
                    source: .user))
            } else if let existing {
                records.append(targetRecord(
                    id, kind: existing.kind, amount: existing.amount, unit: definition.unit, form: definition.form,
                    enabled: false, source: .user))
            }
        }
        guard !records.isEmpty else { return }
        try await store.apply(records.map(StoreOperation.putTarget))
        for record in records {
            targets.removeAll { $0.id == record.id }
            targets.append(record)
        }
    }

    public func setMacroTargetMode(_ mode: MacroTargetMode) async throws {
        var updated = preferences
        updated.macroTargetMode = mode
        try await savePreferences(updated)
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
        let target = targetRecord(
            nutrient, kind: kind, amount: amount, unit: unit, form: form, enabled: enabled, source: source)
        try await store.apply([.putTarget(target)])
        targets.removeAll { $0.id == target.id }
        targets.append(target)
    }

    /// A target record effective from today, replacing one already made today.
    private func targetRecord(
        _ nutrient: NutrientID, kind: TargetKind, amount: Double, unit: NutrientUnit, form: String?, enabled: Bool,
        source: TargetSource
    ) -> NutritionTarget {
        let hasHistory = targets.contains { $0.nutrientID == nutrient }
        let effective = hasHistory ? today : .beginning
        let sameDay = targets.first { $0.nutrientID == nutrient && $0.effectiveDate == effective }
        return NutritionTarget(
            id: sameDay?.id ?? UUID(), nutrientID: nutrient, kind: kind, amount: amount, unit: unit, form: form,
            effectiveDate: effective, enabled: enabled, source: source)
    }

    // MARK: Resetting micronutrient targets

    /// Nutrients with an FDA Daily Value whose target in effect today differs from it. Calories,
    /// macros and nutrients without a Daily Value (such as a caffeine limit) are never included.
    public var customMicronutrientTargets: [NutrientID] {
        Set(targets.map(\.nutrientID)).filter { id in
            guard let definition = NutrientRegistry.definition(for: id), definition.group != .energyAndMacros,
                let reference = FDADailyValues.value(for: id), let record = userTarget(for: id)
            else { return false }
            return !record.enabled || record.kind != reference.kind || record.amount != reference.amount
                || record.unit != reference.unit
        }
        .sorted { $0.rawValue < $1.rawValue }
    }

    /// True when a reset would change anything, including turning FDA values back on.
    public var canResetMicronutrientTargets: Bool {
        !customMicronutrientTargets.isEmpty || !preferences.showReferenceValues
    }

    /// Puts every nutrient that has an FDA Daily Value back to it from today onward, turning any
    /// that were off back on, and shows FDA values again. Earlier days keep their targets.
    @discardableResult
    public func resetMicronutrientTargets() async throws -> TargetReset {
        let custom = customMicronutrientTargets
        let reset = TargetReset(
            nutrients: custom, previous: custom.compactMap { userTarget(for: $0) },
            previousShowReferences: preferences.showReferenceValues)
        let records = custom.compactMap { id -> NutritionTarget? in
            guard let reference = FDADailyValues.value(for: id) else { return nil }
            return targetRecord(
                id, kind: reference.kind, amount: reference.amount, unit: reference.unit, form: reference.form,
                enabled: true, source: .referenceTable(name: FDADailyValues.sourceName, version: FDADailyValues.version))
        }
        var updatedPreferences = preferences
        updatedPreferences.showReferenceValues = true
        var operations = records.map(StoreOperation.putTarget)
        if updatedPreferences != preferences { operations.append(.putPreferences(updatedPreferences)) }
        guard !operations.isEmpty else { return reset }
        try await store.apply(operations)
        for record in records {
            targets.removeAll { $0.id == record.id }
            targets.append(record)
        }
        preferences = updatedPreferences
        return reset
    }

    /// Puts back the targets a reset replaced, from today onward.
    public func undoTargetReset(_ reset: TargetReset) async throws {
        let records = reset.previous.map { old in
            targetRecord(
                old.nutrientID, kind: old.kind, amount: old.amount, unit: old.unit, form: old.form, enabled: old.enabled,
                source: old.source)
        }
        var updatedPreferences = preferences
        updatedPreferences.showReferenceValues = reset.previousShowReferences
        var operations = records.map(StoreOperation.putTarget)
        if updatedPreferences != preferences { operations.append(.putPreferences(updatedPreferences)) }
        guard !operations.isEmpty else { return }
        try await store.apply(operations)
        for record in records {
            targets.removeAll { $0.id == record.id }
            targets.append(record)
        }
        preferences = updatedPreferences
    }

    // MARK: Scheduled meals

    public var activeSchedules: [MealSchedule] { schedules.filter { !$0.isArchived } }

    /// Scheduled meals still to come on the viewed day. They're never counted in the day's totals.
    public var pendingOccurrences: [ScheduledOccurrence] {
        ScheduleEngine.pending(
            on: viewedDate, activeSchedules, handled: Set(outcomesOnViewedDate.keys), now: lastTick, calendar: calendar)
    }

    /// Scheduled meals skipped on the viewed day. They stay visible so they can be brought back.
    public var skippedOccurrences: [ScheduledOccurrence] {
        ScheduleEngine.occurrences(of: activeSchedules, from: viewedDate, through: viewedDate, calendar: calendar)
            .filter { outcomesOnViewedDate[$0.key] == .skipped }
    }

    public func skippedOccurrences(in destination: Destination) -> [ScheduledOccurrence] {
        skippedOccurrences.filter { destinationID(for: $0.schedule) == destination.id }
    }

    public func pendingOccurrences(in destination: Destination) -> [ScheduledOccurrence] {
        pendingOccurrences.filter { destinationID(for: $0.schedule) == destination.id }
    }

    /// What the viewed day's upcoming scheduled meals add up to.
    public var scheduledNutrition: NutritionSummary {
        summarize(pendingOccurrences.flatMap { items(for: $0.schedule) })
    }

    /// The viewed day, section by section, with logged entries and upcoming scheduled meals.
    public var dayOverview: [SectionOverview] {
        let pending = pendingOccurrences
        let skipped = skippedOccurrences
        return destinations.map { destination in
            let logged = entries(in: destination)
            let scheduled = pending.filter { destinationID(for: $0.schedule) == destination.id }
            return SectionOverview(
                destination: destination, entries: logged, scheduled: scheduled,
                skipped: skipped.filter { destinationID(for: $0.schedule) == destination.id },
                loggedEnergy: NutritionCalculator.summarize(entries: logged)[.energy].known,
                scheduledEnergy: summarize(scheduled.flatMap { items(for: $0.schedule) })[.energy].known)
        }
    }

    /// The schedule's meal at its saved quantities. Empty when the meal is gone.
    public func items(for schedule: MealSchedule) -> [DraftItem] {
        guard let meal = meal(id: schedule.mealTemplateID), !meal.isArchived else { return [] }
        return DraftItem.items(for: meal, foods: foods)
    }

    public func nutrition(of schedule: MealSchedule) -> NutritionSummary { summarize(items(for: schedule)) }

    public func mealName(for schedule: MealSchedule) -> String {
        meal(id: schedule.mealTemplateID)?.name ?? "Removed meal"
    }

    public func destinationName(for schedule: MealSchedule) -> String {
        guard let id = schedule.sectionID else { return Destination(section: nil).name }
        return sections.first { $0.id == id }?.name ?? Destination(section: nil).name
    }

    public func schedules(for mealID: UUID) -> [MealSchedule] {
        activeSchedules.filter { $0.mealTemplateID == mealID }
    }

    /// When the next scheduled meal is due, for waking up to log it while the app is open.
    public var nextOccurrenceInstant: Date? {
        let now = clock()
        return ScheduleEngine.occurrences(
            of: activeSchedules, from: today, through: today.adding(days: 1, calendar: calendar), calendar: calendar
        )
        .first { $0.instant > now }?.instant
    }

    /// Call when the app becomes active and periodically while it's open: moves to a new day if
    /// needed, then logs scheduled meals whose time has passed.
    public func tick(isIdle: Bool = true) async {
        await refreshForCurrentDate(isIdle: isIdle)
        await materializeDueOccurrences()
        lastTick = clock()
    }

    /// Logs every scheduled meal whose time has passed (within the lookback) and that wasn't
    /// logged or skipped yet. Each one commits with its occurrence record, so none logs twice.
    @discardableResult
    public func materializeDueOccurrences() async -> [LoggedEntry] {
        let active = activeSchedules
        guard !active.isEmpty, !isMaterializing else { return [] }
        isMaterializing = true
        defer { isMaterializing = false }
        let now = clock()
        guard let records = try? await store.occurrenceRecords(
            from: ScheduleEngine.lookbackStart(now: now, calendar: calendar), through: LogDate(now, calendar: calendar))
        else { return [] }
        var logged: [LoggedEntry] = []
        for occurrence in ScheduleEngine.due(active, handled: Set(records.map(\.key)), now: now, calendar: calendar) {
            if let entry = try? await commit(occurrence, recordedAt: occurrence.instant) { logged.append(entry) }
        }
        guard !logged.isEmpty else { return [] }
        scheduleRevision += 1
        if logged.count == 1, let entry = logged.first {
            toast = Toast(
                message: "Logged \(entry.name) to \(destinationName(for: entry)) · scheduled",
                undo: .removeLogged(entry, previousDestinationID: destinationID, previousDraft: nil, draftKey: ""))
        } else {
            toast = Toast(message: "Logged \(logged.count) scheduled meals", undo: nil)
        }
        return logged
    }

    /// Logs an upcoming scheduled meal right away. Its upcoming row goes away.
    public func logOccurrenceNow(_ occurrence: ScheduledOccurrence) async {
        guard !isLogging else { return }
        isLogging = true
        defer { isLogging = false }
        do {
            guard let entry = try await commit(occurrence, recordedAt: clock()) else {
                errorMessage = "Nothing was logged. That saved meal is no longer available."
                return
            }
            scheduleRevision += 1
            toast = Toast(
                message: "Logged \(entry.name) to \(destinationName(for: entry))",
                undo: .removeLogged(entry, previousDestinationID: destinationID, previousDraft: nil, draftKey: ""))
        } catch {
            errorMessage = "Nothing was logged. \(error.localizedDescription)"
        }
    }

    /// Skips one day of a schedule. The schedule itself carries on.
    public func skipOccurrence(_ occurrence: ScheduledOccurrence) async {
        let name = mealName(for: occurrence.schedule)
        do {
            try await store.apply([
                .recordOccurrence(OccurrenceRecord(key: occurrence.key, outcome: .skipped, handledAt: clock()))
            ])
            markHandled(occurrence.key, .skipped)
            scheduleRevision += 1
            toast = Toast(message: "Skipped \(name)", undo: .unskip(occurrence.key))
        } catch {
            errorMessage = "Couldn’t skip \(name). \(error.localizedDescription)"
        }
    }

    /// Brings back a skipped day. If its time has already passed, it logs right away.
    public func unskipOccurrence(_ occurrence: ScheduledOccurrence) async {
        do {
            try await unskip(occurrence.key)
        } catch {
            errorMessage = "Couldn’t bring back \(mealName(for: occurrence.schedule)). \(error.localizedDescription)"
        }
    }

    private func unskip(_ key: OccurrenceKey) async throws {
        try await store.apply([.deleteOccurrence(key)])
        if key.date == viewedDate { outcomesOnViewedDate[key] = nil }
        scheduleRevision += 1
        await materializeDueOccurrences()
    }

    /// Undoing a scheduled log: an early log goes back to upcoming; one whose time has passed
    /// counts as skipped, so it doesn't log again.
    private func removeScheduledLog(_ entry: LoggedEntry, occurrence key: OccurrenceKey) async throws {
        var operations: [StoreOperation] = [.deleteEntry(entry.id), .deleteOccurrence(key)]
        let upcoming = isUpcoming(key)
        if !upcoming {
            operations.append(.recordOccurrence(OccurrenceRecord(key: key, outcome: .skipped, handledAt: clock())))
        }
        try await store.apply(operations)
        if key.date == viewedDate { outcomesOnViewedDate[key] = upcoming ? nil : .skipped }
        scheduleRevision += 1
    }

    /// Creates or updates a schedule. Missed occurrences log first with the old settings, so an
    /// edit only changes what's still to come.
    public func saveSchedule(_ schedule: MealSchedule) async throws {
        try schedule.validate()
        guard let meal = meal(id: schedule.mealTemplateID), !meal.isArchived else {
            throw ScheduleValidationError.mealUnavailable
        }
        await materializeDueOccurrences()
        let now = clock()
        var saved = schedule
        saved.createdAt = schedules.first { $0.id == schedule.id }?.createdAt ?? now
        saved.updatedAt = now
        saved.activeFrom = now
        saved.archivedAt = nil
        try await store.apply([.putSchedule(saved)])
        replaceSchedules([saved])
    }

    /// Stops a schedule. Meals it already logged stay logged.
    public func deleteSchedule(id: UUID) async throws {
        guard var schedule = schedules.first(where: { $0.id == id }), !schedule.isArchived else { return }
        await materializeDueOccurrences()
        schedule.archivedAt = clock()
        schedule.updatedAt = clock()
        try await store.apply([.putSchedule(schedule)])
        replaceSchedules([schedule])
    }

    /// Notifications for upcoming scheduled meals that ask for one.
    public func notificationPlan() async -> [PlannedNotification] {
        let now = clock()
        let first = LogDate(now, calendar: calendar)
        let records = (try? await store.occurrenceRecords(from: first, through: first.adding(days: 7, calendar: calendar))) ?? []
        return ScheduleEngine.notificationPlan(
            activeSchedules, handled: Set(records.map(\.key)), now: now, calendar: calendar
        ) { occurrence in
            let mealItems = items(for: occurrence.schedule)
            guard !mealItems.isEmpty else { return nil }
            return (
                mealName(for: occurrence.schedule), summarize(mealItems)[.energy].known,
                destinationName(for: occurrence.schedule)
            )
        }
    }

    /// Logs one occurrence together with its record. A meal that's gone is recorded as skipped,
    /// so it isn't retried, and nil is returned.
    private func commit(_ occurrence: ScheduledOccurrence, recordedAt: Date) async throws -> LoggedEntry? {
        let schedule = occurrence.schedule
        let mealItems = items(for: schedule)
        guard let meal = meal(id: schedule.mealTemplateID), !mealItems.isEmpty else {
            try await store.apply([
                .recordOccurrence(OccurrenceRecord(key: occurrence.key, outcome: .skipped, handledAt: clock()))
            ])
            markHandled(occurrence.key, .skipped)
            return nil
        }
        let entryID = UUID()
        let section = schedule.sectionID.flatMap { id in activeSections.first { $0.id == id } }
        let record = OccurrenceRecord(key: occurrence.key, outcome: .logged(entryID: entryID), handledAt: clock())
        // A one-time schedule is done once it logs.
        var finished: MealSchedule?
        if case .once = schedule.recurrence {
            finished = schedule
            finished?.archivedAt = clock()
            finished?.updatedAt = clock()
        }
        let request = LogRequest(
            name: meal.name, mealTemplateID: meal.id, items: mealItems, logDate: occurrence.key.date, section: section,
            path: .normal, additionalOperations: [.recordOccurrence(record)] + (finished.map { [.putSchedule($0)] } ?? []),
            recordedAt: recordedAt, scheduleOccurrence: occurrence.key, entryID: entryID)
        let entry = try await logging.log(request)
        if let finished { replaceSchedules([finished]) }
        markHandled(occurrence.key, .logged(entryID: entryID))
        insertLocally(entry)
        return entry
    }

    private func markHandled(_ key: OccurrenceKey, _ outcome: OccurrenceOutcome) {
        if key.date == viewedDate { outcomesOnViewedDate[key] = outcome }
    }

    /// True while an occurrence's time is still ahead.
    private func isUpcoming(_ key: OccurrenceKey) -> Bool {
        guard let schedule = schedules.first(where: { $0.id == key.scheduleID }) else { return false }
        return ScheduleEngine.instant(of: schedule, on: key.date, calendar: calendar) > clock()
    }

    private func occurrenceOutcomes(on date: LogDate) async throws -> [OccurrenceKey: OccurrenceOutcome] {
        let records = try await store.occurrenceRecords(from: date, through: date)
        return Dictionary(records.map { ($0.key, $0.outcome) }, uniquingKeysWith: { $1 })
    }

    private func destinationID(for schedule: MealSchedule) -> String {
        guard let id = schedule.sectionID, activeSections.contains(where: { $0.id == id }) else {
            return SectionKey.unsectioned
        }
        return SectionKey.key(for: id)
    }

    private func summarize(_ items: [DraftItem]) -> NutritionSummary {
        (try? NutritionCalculator.summarize(items.map(\.calculatorItem))) ?? NutritionSummary()
    }

    /// Copies of the active schedules matching `predicate`, archived now.
    private func archivedSchedules(where predicate: (MealSchedule) -> Bool) -> [MealSchedule] {
        activeSchedules.filter(predicate).map { schedule in
            var copy = schedule
            copy.archivedAt = clock()
            copy.updatedAt = clock()
            return copy
        }
    }

    private func replaceSchedules(_ changed: [MealSchedule]) {
        guard !changed.isEmpty else { return }
        for schedule in changed {
            if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                schedules[index] = schedule
            } else {
                schedules.append(schedule)
            }
        }
        scheduleRevision += 1
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
            preferences: configuration.preferences, schedules: configuration.schedules,
            occurrences: try await store.allOccurrenceRecords())
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
