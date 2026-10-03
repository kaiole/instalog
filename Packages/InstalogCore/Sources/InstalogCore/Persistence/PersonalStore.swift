import Foundation

/// One change to personal data. A batch of operations commits atomically.
public enum StoreOperation: Sendable {
    case putFood(FoodDefinition)
    case putMeal(MealTemplate)
    case putSection(RoutineSection)
    case putEntry(LoggedEntry)
    case deleteEntry(UUID)
    case putTarget(NutritionTarget)
    case putPreferences(AppPreferences)
    case putNavigation(NavigationMemory)
}

/// Everything except logged history, which is loaded per day.
public struct PersonalConfiguration: Sendable, Equatable {
    public var foods: [FoodDefinition]
    public var meals: [MealTemplate]
    public var sections: [RoutineSection]
    public var targets: [NutritionTarget]
    public var preferences: AppPreferences
    public var navigation: NavigationMemory?

    public init(
        foods: [FoodDefinition] = [], meals: [MealTemplate] = [], sections: [RoutineSection] = [],
        targets: [NutritionTarget] = [], preferences: AppPreferences = AppPreferences(),
        navigation: NavigationMemory? = nil
    ) {
        self.foods = foods
        self.meals = meals
        self.sections = sections
        self.targets = targets
        self.preferences = preferences
        self.navigation = navigation
    }
}

/// All personal records, as exported and imported.
public struct PersonalDataSet: Sendable, Codable, Equatable {
    public var foods: [FoodDefinition]
    public var meals: [MealTemplate]
    public var sections: [RoutineSection]
    public var entries: [LoggedEntry]
    public var targets: [NutritionTarget]
    public var preferences: AppPreferences

    public init(
        foods: [FoodDefinition] = [], meals: [MealTemplate] = [], sections: [RoutineSection] = [],
        entries: [LoggedEntry] = [], targets: [NutritionTarget] = [], preferences: AppPreferences = AppPreferences()
    ) {
        self.foods = foods
        self.meals = meals
        self.sections = sections
        self.entries = entries
        self.targets = targets
        self.preferences = preferences
    }
}

public protocol PersonalStore: Sendable {
    func loadConfiguration() async throws -> PersonalConfiguration
    func entries(on date: LogDate) async throws -> [LoggedEntry]
    func allEntries() async throws -> [LoggedEntry]
    /// The most recently dated entries, newest first.
    func recentEntries(limit: Int) async throws -> [LoggedEntry]
    /// Days in `first...last` that have at least one entry.
    func datesWithEntries(from first: LogDate, through last: LogDate) async throws -> Set<LogDate>
    /// Applies every operation in one transaction, or none of them.
    func apply(_ operations: [StoreOperation]) async throws
    /// Atomically replaces all personal data (navigation memory is cleared).
    func replaceAll(with data: PersonalDataSet) async throws
}

/// SQLite-backed personal store. Each record is a JSON document with indexed lookup columns,
/// so a day's entries are fetched by `log_date` without loading the whole history.
public actor SQLitePersonalStore: PersonalStore {
    static let schemaVersion = 1

    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opens (creating if needed) the store at `url`. Pass nil for an in-memory store.
    public init(url: URL?) throws {
        connection = try SQLiteConnection(path: url?.path ?? ":memory:")
        if url != nil {
            try connection.execute("PRAGMA journal_mode = WAL")
            try connection.execute("PRAGMA synchronous = FULL")
        }
        try Self.migrate(connection)
    }

    /// The default on-device location inside Application Support.
    public static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Instalog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("personal.sqlite")
    }

    private static func migrate(_ connection: SQLiteConnection) throws {
        let version = connection.userVersion
        guard version < schemaVersion else { return }
        try connection.transaction {
            if version < 1 {
                try connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS foods (
                        id TEXT PRIMARY KEY, catalog_key TEXT, json BLOB NOT NULL);
                    CREATE INDEX IF NOT EXISTS foods_by_catalog_key ON foods(catalog_key);
                    CREATE TABLE IF NOT EXISTS meals (
                        id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, json BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sections (
                        id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, json BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS entries (
                        id TEXT PRIMARY KEY, log_date TEXT NOT NULL, section_id TEXT,
                        recorded_at REAL NOT NULL, json BLOB NOT NULL);
                    CREATE INDEX IF NOT EXISTS entries_by_date ON entries(log_date, recorded_at);
                    CREATE TABLE IF NOT EXISTS targets (
                        id TEXT PRIMARY KEY, nutrient_id TEXT NOT NULL, effective_date TEXT NOT NULL,
                        json BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, json BLOB NOT NULL);
                    """)
            }
            try connection.setUserVersion(schemaVersion)
        }
    }

    public func loadConfiguration() throws -> PersonalConfiguration {
        PersonalConfiguration(
            foods: try documents("SELECT json FROM foods"),
            meals: try documents("SELECT json FROM meals ORDER BY sort_order"),
            sections: try documents("SELECT json FROM sections ORDER BY sort_order"),
            targets: try documents("SELECT json FROM targets ORDER BY effective_date"),
            preferences: try setting("preferences") ?? AppPreferences(),
            navigation: try setting("navigation")
        )
    }

    public func entries(on date: LogDate) throws -> [LoggedEntry] {
        try documents(
            "SELECT json FROM entries WHERE log_date = ? ORDER BY recorded_at, id", [.text(date.description)])
    }

    public func allEntries() throws -> [LoggedEntry] {
        try documents("SELECT json FROM entries ORDER BY log_date, recorded_at, id")
    }

    public func datesWithEntries(from first: LogDate, through last: LogDate) throws -> Set<LogDate> {
        let statement = try connection.prepare("SELECT DISTINCT log_date FROM entries WHERE log_date BETWEEN ? AND ?")
        try statement.bind([.text(first.description), .text(last.description)])
        var dates = Set<LogDate>()
        while try statement.step() {
            if let text = statement.text(0), let date = LogDate(string: text) { dates.insert(date) }
        }
        return dates
    }

    public func recentEntries(limit: Int) throws -> [LoggedEntry] {
        try documents(
            "SELECT json FROM entries ORDER BY log_date DESC, recorded_at DESC, id DESC LIMIT ?",
            [.integer(Int64(max(0, limit)))])
    }

    public func apply(_ operations: [StoreOperation]) throws {
        try connection.transaction {
            for operation in operations { try write(operation) }
        }
    }

    public func replaceAll(with data: PersonalDataSet) throws {
        try connection.transaction {
            for table in ["foods", "meals", "sections", "entries", "targets", "settings"] {
                try connection.execute("DELETE FROM \(table)")
            }
            for food in data.foods { try write(.putFood(food)) }
            for meal in data.meals { try write(.putMeal(meal)) }
            for section in data.sections { try write(.putSection(section)) }
            for entry in data.entries { try write(.putEntry(entry)) }
            for target in data.targets { try write(.putTarget(target)) }
            try write(.putPreferences(data.preferences))
        }
    }

    private func write(_ operation: StoreOperation) throws {
        switch operation {
        case .putFood(let food):
            try upsert(
                "INSERT OR REPLACE INTO foods (id, catalog_key, json) VALUES (?, ?, ?)",
                [.text(food.id.uuidString), food.catalogKey.map { .text($0) } ?? .null], food)
        case .putMeal(let meal):
            try upsert(
                "INSERT OR REPLACE INTO meals (id, sort_order, json) VALUES (?, ?, ?)",
                [.text(meal.id.uuidString), .integer(Int64(meal.sortOrder))], meal)
        case .putSection(let section):
            try upsert(
                "INSERT OR REPLACE INTO sections (id, sort_order, json) VALUES (?, ?, ?)",
                [.text(section.id.uuidString), .integer(Int64(section.sortOrder))], section)
        case .putEntry(let entry):
            try upsert(
                "INSERT OR REPLACE INTO entries (id, log_date, section_id, recorded_at, json) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(entry.id.uuidString), .text(entry.logDate.description),
                    entry.sectionID.map { .text($0.uuidString) } ?? .null,
                    .real(entry.recordedAt.timeIntervalSince1970),
                ], entry)
        case .deleteEntry(let id):
            try connection.prepare("DELETE FROM entries WHERE id = ?").bind(.text(id.uuidString)).run()
        case .putTarget(let target):
            try upsert(
                "INSERT OR REPLACE INTO targets (id, nutrient_id, effective_date, json) VALUES (?, ?, ?, ?)",
                [.text(target.id.uuidString), .text(target.nutrientID.rawValue), .text(target.effectiveDate.description)],
                target)
        case .putPreferences(let preferences):
            try upsert("INSERT OR REPLACE INTO settings (key, json) VALUES (?, ?)", [.text("preferences")], preferences)
        case .putNavigation(let navigation):
            try upsert("INSERT OR REPLACE INTO settings (key, json) VALUES (?, ?)", [.text("navigation")], navigation)
        }
    }

    private func upsert<T: Encodable>(_ sql: String, _ columns: [SQLiteValue], _ document: T) throws {
        try connection.prepare(sql).bind(columns + [.blob(try encoder.encode(document))]).run()
    }

    private func documents<T: Decodable>(_ sql: String, _ values: [SQLiteValue] = []) throws -> [T] {
        let statement = try connection.prepare(sql)
        try statement.bind(values)
        var results: [T] = []
        while try statement.step() {
            results.append(try decoder.decode(T.self, from: statement.blob(0)))
        }
        return results
    }

    private func setting<T: Decodable>(_ key: String) throws -> T? {
        let results: [T] = try documents("SELECT json FROM settings WHERE key = ?", [.text(key)])
        return results.first
    }
}
