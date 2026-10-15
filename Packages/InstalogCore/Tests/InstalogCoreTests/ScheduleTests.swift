import Foundation
import Testing
@testable import InstalogCore

@Suite("Schedule occurrences")
struct ScheduleEngineTests {
    private let calendar = Calendar.current
    private let thursday = LogDate(year: 2026, month: 10, day: 1)

    private func schedule(_ recurrence: ScheduleRecurrence, minute: Int = 12 * 60 + 30, activeFrom: Date) -> MealSchedule {
        MealSchedule(mealTemplateID: UUID(), sectionID: nil, minuteOfDay: minute, recurrence: recurrence, activeFrom: activeFrom)
    }

    @Test("Weekday schedules fall only on their days, at the local time")
    func weekdays() {
        let weekdays = schedule(.weekly([2, 3, 4, 5, 6]), activeFrom: TestClock.date(2026, 10, 1, hour: 8))
        let found = ScheduleEngine.occurrences(
            of: [weekdays], from: thursday, through: thursday.adding(days: 6), calendar: calendar)
        #expect(found.map(\.key.date.day) == [1, 2, 5, 6, 7], "Thu, Fri, then Mon–Wed; no weekend")
        #expect(found[0].instant == TestClock.date(2026, 10, 1, hour: 12).addingTimeInterval(30 * 60))
    }

    @Test("A one-off schedule falls on its date only")
    func once() {
        let saturday = thursday.adding(days: 2)
        let oneOff = schedule(.once(saturday), activeFrom: TestClock.date(2026, 10, 1, hour: 8))
        let found = ScheduleEngine.occurrences(
            of: [oneOff], from: thursday, through: thursday.adding(days: 6), calendar: calendar)
        #expect(found.map(\.key.date) == [saturday])
    }

    @Test("Nothing is created for times before the schedule existed")
    func createdAfterItsTime() {
        let daily = schedule(.weekly(Set(1...7)), activeFrom: TestClock.date(2026, 10, 1, hour: 14))
        let found = ScheduleEngine.occurrences(of: [daily], from: thursday, through: thursday.adding(days: 1), calendar: calendar)
        #expect(found.map(\.key.date) == [thursday.adding(days: 1)])
    }

    @Test("Archived schedules have no occurrences")
    func archived() {
        var daily = schedule(.weekly(Set(1...7)), activeFrom: TestClock.date(2026, 10, 1, hour: 8))
        daily.archivedAt = TestClock.date(2026, 10, 1, hour: 9)
        #expect(ScheduleEngine.occurrences(of: [daily], from: thursday, through: thursday, calendar: calendar).isEmpty)
    }

    @Test("Due and pending split on the current time and skip handled occurrences")
    func dueAndPending() {
        let daily = schedule(.weekly(Set(1...7)), activeFrom: TestClock.date(2026, 9, 1, hour: 8))
        let noon = TestClock.date(2026, 10, 1, hour: 12)
        #expect(ScheduleEngine.pending(on: thursday, [daily], handled: [], now: noon, calendar: calendar).count == 1)
        let due = ScheduleEngine.due([daily], handled: [], now: noon, calendar: calendar)
        #expect(due.count == ScheduleEngine.lookbackDays, "Seven earlier days; today's isn't due yet")
        let handled = Set(due.map(\.key))
        #expect(ScheduleEngine.due([daily], handled: handled, now: noon, calendar: calendar).isEmpty)
    }

    @Test("Invalid times and empty day sets are rejected")
    func validation() {
        let active = TestClock.date(2026, 10, 1)
        #expect(throws: ScheduleValidationError.invalidTime) { try schedule(.weekly([2]), minute: 1440, activeFrom: active).validate() }
        #expect(throws: ScheduleValidationError.noDays) { try schedule(.weekly([]), activeFrom: active).validate() }
        #expect(throws: ScheduleValidationError.noDays) { try schedule(.weekly([0]), activeFrom: active).validate() }
    }
}

@MainActor
@Suite("Scheduled meals")
struct ScheduledMealTests {
    let clock = TestClock()

    private func seeded() async throws -> (DiaryModel, Routine, SQLitePersonalStore) {
        let store = try SQLitePersonalStore(url: nil)
        let routine = try await Scenario.seedRoutine(into: store)
        return (await Scenario.model(store: store, clock: clock), routine, store)
    }

    /// Lunch bowl into Lunch every day at 12:30, created at the clock's current time.
    @discardableResult
    private func scheduleLunch(
        _ model: DiaryModel, _ routine: Routine, days: Set<Int> = Set(1...7), notify: Bool = false
    ) async throws -> MealSchedule {
        let schedule = MealSchedule(
            mealTemplateID: routine.lunchMeal.id, sectionID: routine.lunch.id, minuteOfDay: 12 * 60 + 30,
            recurrence: .weekly(days), notify: notify)
        try await model.saveSchedule(schedule)
        return model.schedules.first { $0.id == schedule.id }!
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestClock.date(2026, 10, day, hour: hour).addingTimeInterval(TimeInterval(minute * 60))
    }

    private func lunch(_ model: DiaryModel, _ routine: Routine) -> Destination {
        model.destinations.first { $0.section?.id == routine.lunch.id }!
    }

    @Test("Before its time a scheduled meal is upcoming and not counted")
    func upcomingNotCounted() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)

        #expect(model.pendingOccurrences(in: lunch(model, routine)).count == 1)
        #expect(model.entries.isEmpty)
        #expect(model.dayNutrition.isEmpty)
        #expect(model.scheduledNutrition[.energy].known.isClose(to: 300))
        let overview = model.dayOverview.first { $0.destination.section?.id == routine.lunch.id }!
        #expect(overview.scheduled.count == 1)
        #expect(overview.scheduledEnergy.isClose(to: 300))
        #expect(overview.loggedEnergy == 0)
    }

    @Test("Once its time passes it logs exactly once, at the scheduled time")
    func logsOnce() async throws {
        let (model, routine, store) = try await seeded()
        let schedule = try await scheduleLunch(model, routine)
        clock.set(at(1, 12, 31))
        await model.tick()

        #expect(model.entries.count == 1)
        let entry = model.entries[0]
        #expect(entry.recordedAt == at(1, 12, 30))
        #expect(entry.sectionID == routine.lunch.id)
        #expect(entry.mealTemplateID == routine.lunchMeal.id)
        #expect(entry.scheduleOccurrence == OccurrenceKey(scheduleID: schedule.id, date: model.today))
        #expect(model.pendingOccurrences.isEmpty)
        #expect(model.toast?.message == "Logged Lunch bowl to Lunch · scheduled")

        await model.tick()
        let reopened = await Scenario.model(store: store, clock: clock)
        await reopened.tick()
        #expect(try await store.entries(on: model.today).count == 1)
    }

    @Test("Logging by hand never cancels a scheduled meal")
    func manualLogKeepsSchedule() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        model.selectDestination(id: lunch(model, routine).id)
        #expect(await model.logSelectedMeal())
        #expect(model.pendingOccurrences.count == 1)

        clock.set(at(1, 13))
        await model.tick()
        #expect(model.entries.count == 2)
    }

    @Test("A deleted scheduled entry stays deleted")
    func deletedStaysDeleted() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        clock.set(at(1, 13))
        await model.tick()
        await model.deleteEntry(model.entries[0])
        await model.tick()
        #expect(model.entries.isEmpty)
        #expect(model.pendingOccurrences.isEmpty)
    }

    @Test("Undoing an automatic log counts as skipping that day")
    func undoAutoLog() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        clock.set(at(1, 13))
        await model.tick()
        await model.undo(try #require(model.toast))
        await model.tick()
        #expect(model.entries.isEmpty)
        #expect(model.skippedOccurrences.count == 1)
    }

    @Test("A skipped day stays visible, never logs, and can be brought back")
    func skip() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        await model.skipOccurrence(try #require(model.pendingOccurrences.first))
        #expect(model.pendingOccurrences.isEmpty)
        #expect(model.skippedOccurrences(in: lunch(model, routine)).count == 1)
        #expect(model.scheduledNutrition.isEmpty)
        let skipToast = try #require(model.toast)

        clock.set(at(1, 13))
        await model.tick()
        #expect(model.entries.isEmpty)
        #expect(model.dayOverview.flatMap(\.skipped).count == 1)

        await model.undo(skipToast)
        #expect(model.entries.count == 1)
        #expect(model.skippedOccurrences.isEmpty)
    }

    @Test("Un-skipping before its time puts the meal back as upcoming")
    func unskipEarly() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        await model.skipOccurrence(try #require(model.pendingOccurrences.first))
        await model.unskipOccurrence(try #require(model.skippedOccurrences.first))
        #expect(model.pendingOccurrences.count == 1)
        #expect(model.skippedOccurrences.isEmpty)
        #expect(model.entries.isEmpty)
    }

    @Test("Log now logs immediately, and undo brings the upcoming row back")
    func logNow() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        await model.logOccurrenceNow(try #require(model.pendingOccurrences.first))
        #expect(model.entries.count == 1)
        #expect(model.entries[0].recordedAt == clock.now)
        #expect(model.pendingOccurrences.isEmpty)

        await model.undo(try #require(model.toast))
        #expect(model.entries.isEmpty)
        #expect(model.pendingOccurrences.count == 1)

        clock.set(at(1, 13))
        await model.tick()
        #expect(model.entries.count == 1, "Still logs at its time after the early log was undone")
    }

    @Test("Missed days log on their own dates, within the lookback")
    func missedDays() async throws {
        let (model, routine, store) = try await seeded()
        try await scheduleLunch(model, routine)
        clock.set(at(3, 20))
        await model.tick()
        for day in 1...3 {
            #expect(try await store.entries(on: LogDate(year: 2026, month: 10, day: day)).count == 1)
        }
        #expect(model.toast?.message == "Logged 3 scheduled meals")
    }

    @Test("After a long absence only the last week logs")
    func lookbackCap() async throws {
        let (model, routine, store) = try await seeded()
        try await scheduleLunch(model, routine)
        clock.set(at(21, 20))
        await model.tick()
        let logged = try await store.allEntries()
        #expect(logged.count == ScheduleEngine.lookbackDays + 1)
        #expect(logged.map(\.logDate).min() == LogDate(year: 2026, month: 10, day: 14))
    }

    @Test("Editing a schedule logs what was missed first, then only changes what's to come")
    func editAfterMiss() async throws {
        let (model, routine, store) = try await seeded()
        var schedule = try await scheduleLunch(model, routine)
        clock.set(at(1, 13))
        schedule.mealTemplateID = routine.shakeMeal.id
        try await model.saveSchedule(schedule)
        #expect(model.entries.map(\.mealTemplateID) == [routine.lunchMeal.id])

        clock.set(at(2, 13))
        await model.tick()
        let tomorrow = try await store.entries(on: LogDate(year: 2026, month: 10, day: 2))
        #expect(tomorrow.map(\.mealTemplateID) == [routine.shakeMeal.id])
    }

    @Test("Moving a schedule earlier than now doesn't log today twice or retroactively")
    func editToEarlierTime() async throws {
        let (model, routine, _) = try await seeded()
        var schedule = try await scheduleLunch(model, routine)
        clock.set(at(1, 11))
        schedule.minuteOfDay = 10 * 60
        try await model.saveSchedule(schedule)
        await model.tick()
        #expect(model.entries.isEmpty)
        #expect(model.pendingOccurrences.isEmpty)
    }

    @Test("A one-time schedule logs on its day and is then done")
    func once() async throws {
        let (model, routine, store) = try await seeded()
        let tomorrow = model.today.adding(days: 1)
        try await model.saveSchedule(MealSchedule(
            mealTemplateID: routine.lunchMeal.id, sectionID: routine.lunch.id, minuteOfDay: 19 * 60,
            recurrence: .once(tomorrow)))
        clock.set(at(3, 9))
        await model.tick()
        #expect(try await store.entries(on: tomorrow).count == 1)
        #expect(model.activeSchedules.isEmpty)
    }

    @Test("Removing a saved meal or a section stops its schedules")
    func cascade() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        try await model.archiveMeal(id: routine.lunchMeal.id)
        #expect(model.activeSchedules.isEmpty)
        #expect(model.pendingOccurrences.isEmpty)

        let shake = MealSchedule(
            mealTemplateID: routine.shakeMeal.id, sectionID: routine.snack.id, minuteOfDay: 16 * 60,
            recurrence: .weekly(Set(1...7)))
        try await model.saveSchedule(shake)
        try await model.removeSection(id: routine.snack.id)
        #expect(model.activeSchedules.isEmpty)

        clock.set(at(1, 20))
        await model.tick()
        #expect(model.entries.isEmpty)
    }

    @Test("Schedules need an available saved meal")
    func needsMeal() async throws {
        let (model, routine, _) = try await seeded()
        try await model.archiveMeal(id: routine.lunchMeal.id)
        await #expect(throws: ScheduleValidationError.mealUnavailable) {
            try await scheduleLunch(model, routine)
        }
    }

    @Test("Upcoming meals show on future days and don't count there either")
    func futureDays() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine, days: [6])
        #expect(model.pendingOccurrences.isEmpty, "Thursday isn't a Friday")
        await model.showAdjacentDay(1)
        #expect(model.pendingOccurrences.count == 1)
        #expect(model.dayNutrition.isEmpty)
    }

    @Test("Notifications are planned only for schedules that ask, with stable IDs")
    func notifications() async throws {
        let (model, routine, _) = try await seeded()
        let quiet = try await scheduleLunch(model, routine)
        try await model.deleteSchedule(id: quiet.id)
        let loud = try await scheduleLunch(model, routine, days: [5], notify: true)

        let plan = await model.notificationPlan()
        #expect(plan.count == 2, "This Thursday and next")
        #expect(plan[0].id == "schedule.\(loud.id.uuidString).2026-10-01")
        #expect(plan[0].fireDate == at(1, 12, 30))
        #expect(plan[0].title == "Logged Lunch bowl")
        #expect(plan[0].body.contains("300 kcal"))
        #expect(plan[0].body.contains("Lunch"))

        await model.skipOccurrence(try #require(model.pendingOccurrences.first))
        #expect(await model.notificationPlan().count == 1)
    }

    @Test("Schedules and their records survive export and import")
    func exportRoundTrip() async throws {
        let (model, routine, _) = try await seeded()
        try await scheduleLunch(model, routine)
        clock.set(at(1, 13))
        await model.tick()

        let data = try ExportService.decode(try await model.exportData())
        #expect(data.schedules.count == 1)
        #expect(data.occurrences.count == 1)

        let destination = try SQLitePersonalStore(url: nil)
        try await destination.replaceAll(with: data)
        let imported = await Scenario.model(store: destination, clock: clock)
        await imported.tick()
        #expect(try await destination.allEntries().count == 1, "The imported record prevents a second log")
    }
}

@Suite("Schedule persistence")
struct SchedulePersistenceTests {
    @Test("Recording the same occurrence twice rolls back the whole batch")
    func duplicateRollsBack() async throws {
        let store = try SQLitePersonalStore(url: nil)
        let key = OccurrenceKey(scheduleID: UUID(), date: LogDate(year: 2026, month: 10, day: 1))
        let record = OccurrenceRecord(key: key, outcome: .skipped, handledAt: Date())
        try await store.apply([.recordOccurrence(record)])
        let entry = LoggedEntry(
            logDate: key.date, recordedAt: Date(), sectionID: nil, sectionName: nil, mealTemplateID: nil, name: "Food A",
            path: .additional, foods: [LoggedFoodSnapshot(food: Fixtures.foodA, quantity: 50, unit: .gram)])
        await #expect(throws: (any Error).self) {
            try await store.apply([.putEntry(entry), .recordOccurrence(record)])
        }
        #expect(try await store.allEntries().isEmpty)
    }

    @Test("A version 1 database opens and gains schedules")
    func migratesVersion1() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("instalog-v1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute(
                """
                CREATE TABLE foods (id TEXT PRIMARY KEY, catalog_key TEXT, json BLOB NOT NULL);
                CREATE TABLE meals (id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, json BLOB NOT NULL);
                CREATE TABLE sections (id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, json BLOB NOT NULL);
                CREATE TABLE entries (
                    id TEXT PRIMARY KEY, log_date TEXT NOT NULL, section_id TEXT, recorded_at REAL NOT NULL,
                    json BLOB NOT NULL);
                CREATE TABLE targets (
                    id TEXT PRIMARY KEY, nutrient_id TEXT NOT NULL, effective_date TEXT NOT NULL, json BLOB NOT NULL);
                CREATE TABLE settings (key TEXT PRIMARY KEY, json BLOB NOT NULL);
                """)
            try connection.setUserVersion(1)
        }
        let store = try SQLitePersonalStore(url: url)
        let meal = Fixtures.meal("Oats", [(Fixtures.oats, 60)], order: 0)
        let schedule = MealSchedule(mealTemplateID: meal.id, sectionID: nil, minuteOfDay: 480, recurrence: .weekly([2]))
        try await store.apply([.putFood(Fixtures.oats), .putMeal(meal), .putSchedule(schedule)])
        #expect(try await store.loadConfiguration().schedules == [schedule])
    }

    @Test("Version 1 exports, which have no schedules, still import")
    func importsVersion1() throws {
        let file = try ExportService.encode(PersonalDataSet(foods: [Fixtures.foodA]))
        var json = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        var data = try #require(json["data"] as? [String: Any])
        data["schedules"] = nil
        data["occurrences"] = nil
        json["data"] = data
        json["schemaVersion"] = 1
        let decoded = try ExportService.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.foods == [Fixtures.foodA])
        #expect(decoded.schedules.isEmpty)
    }

    @Test("Imports reject schedules for unknown meals")
    func rejectsOrphanSchedules() throws {
        var data = PersonalDataSet(foods: [Fixtures.foodA])
        data.schedules = [MealSchedule(mealTemplateID: UUID(), sectionID: nil, minuteOfDay: 480, recurrence: .weekly([2]))]
        #expect(throws: ImportError.self) { try ExportService.decode(try ExportService.encode(data)) }
    }
}
