import Foundation

public struct LogRequest: Sendable {
    public var name: String
    public var mealTemplateID: UUID?
    public var items: [DraftItem]
    public var logDate: LogDate
    public var section: RoutineSection?
    public var path: EntryPath
    /// Extra writes that must commit together with the entry (e.g. saving a one-off as a meal).
    public var additionalOperations: [StoreOperation]

    public init(
        name: String, mealTemplateID: UUID?, items: [DraftItem], logDate: LogDate, section: RoutineSection?, path: EntryPath,
        additionalOperations: [StoreOperation] = []
    ) {
        self.name = name
        self.mealTemplateID = mealTemplateID
        self.items = items
        self.logDate = logDate
        self.section = section
        self.path = path
        self.additionalOperations = additionalOperations
    }
}

/// The single logging path for both saved-meal logs and Add food. Builds immutable snapshots,
/// validates, and commits the entry with all of its foods in one transaction.
public struct LoggingService: Sendable {
    public let store: any PersonalStore
    public let now: @Sendable () -> Date

    public init(store: any PersonalStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Zero-quantity items are omitted from the entry; they stay in the saved template.
    public func makeEntry(_ request: LogRequest) throws -> LoggedEntry {
        let foods = request.items.filter { $0.quantity > 0 }.map { item in
            LoggedFoodSnapshot(
                food: item.food, quantity: item.quantity, unit: item.unit, templateQuantity: item.templateQuantity)
        }
        let entry = LoggedEntry(
            logDate: request.logDate, recordedAt: now(), sectionID: request.section?.id,
            sectionName: request.section?.name, mealTemplateID: request.mealTemplateID,
            name: request.name.trimmingCharacters(in: .whitespacesAndNewlines), path: request.path, foods: foods)
        try entry.validate()
        return entry
    }

    @discardableResult
    public func log(_ request: LogRequest) async throws -> LoggedEntry {
        let entry = try makeEntry(request)
        let foodWrites = uniqueFoods(in: request.items.filter { $0.quantity > 0 }).map(StoreOperation.putFood)
        try await store.apply(foodWrites + request.additionalOperations + [.putEntry(entry)])
        return entry
    }

    /// Saves edits to one logged instance. Templates and other entries are untouched.
    public func update(_ entry: LoggedEntry) async throws -> LoggedEntry {
        var updated = entry
        updated.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.foods = entry.foods.filter { $0.quantity > 0 }
        updated.updatedAt = now()
        try updated.validate()
        try await store.apply([.putEntry(updated)])
        return updated
    }

    public func delete(_ entry: LoggedEntry) async throws {
        try await store.apply([.deleteEntry(entry.id)])
    }

    /// Restores a deleted entry exactly as it was.
    public func restore(_ entry: LoggedEntry) async throws {
        try await store.apply([.putEntry(entry)])
    }

    private func uniqueFoods(in items: [DraftItem]) -> [FoodDefinition] {
        var seen = Set<UUID>()
        return items.compactMap { seen.insert($0.food.id).inserted ? $0.food : nil }
    }
}
