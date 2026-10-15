import Foundation

/// A notification to post when a scheduled meal logs.
public struct PlannedNotification: Hashable, Sendable, Identifiable {
    public static let identifierPrefix = "schedule."

    public var id: String
    public var fireDate: Date
    public var title: String
    public var body: String
}

/// Pure occurrence arithmetic for meal schedules. Every function takes the calendar and the
/// current time, so results are deterministic.
public enum ScheduleEngine {
    /// How far back missed occurrences still log. After a longer absence, showing nothing is more
    /// honest than weeks of meals that may not have been eaten.
    public static let lookbackDays = 7
    /// iOS keeps at most 64 pending local notifications per app; leave some headroom.
    public static let maxNotifications = 60

    public static func falls(_ schedule: MealSchedule, on date: LogDate, calendar: Calendar) -> Bool {
        switch schedule.recurrence {
        case .once(let day): return day == date
        case .weekly(let days): return days.contains(calendar.component(.weekday, from: date.startOfDay(in: calendar)))
        }
    }

    /// The local time the schedule falls on that day. A time skipped by a daylight-saving change
    /// moves to the next valid time.
    public static func instant(of schedule: MealSchedule, on date: LogDate, calendar: Calendar) -> Date {
        let midnight = date.startOfDay(in: calendar)
        return calendar.date(
            bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: midnight, matchingPolicy: .nextTime)
            ?? midnight.addingTimeInterval(TimeInterval(schedule.minuteOfDay * 60))
    }

    /// The schedule's occurrence on `date`, if it has one there.
    public static func occurrence(of schedule: MealSchedule, on date: LogDate, calendar: Calendar) -> ScheduledOccurrence? {
        guard !schedule.isArchived, falls(schedule, on: date, calendar: calendar) else { return nil }
        let instant = instant(of: schedule, on: date, calendar: calendar)
        guard instant >= schedule.activeFrom else { return nil }
        return ScheduledOccurrence(key: OccurrenceKey(scheduleID: schedule.id, date: date), schedule: schedule, instant: instant)
    }

    /// Occurrences on the days `first...last`, in time order.
    public static func occurrences(
        of schedules: [MealSchedule], from first: LogDate, through last: LogDate, calendar: Calendar
    ) -> [ScheduledOccurrence] {
        guard first <= last else { return [] }
        var result: [ScheduledOccurrence] = []
        var day = first
        while day <= last {
            result += schedules.compactMap { occurrence(of: $0, on: day, calendar: calendar) }
            day = day.adding(days: 1, calendar: calendar)
        }
        return result.sorted { ($0.instant, $0.key.scheduleID.uuidString) < ($1.instant, $1.key.scheduleID.uuidString) }
    }

    /// The first day missed occurrences are still logged for.
    public static func lookbackStart(now: Date, calendar: Calendar) -> LogDate {
        LogDate(now, calendar: calendar).adding(days: -lookbackDays, calendar: calendar)
    }

    /// Occurrences whose time has passed and that haven't been logged or skipped.
    public static func due(
        _ schedules: [MealSchedule], handled: Set<OccurrenceKey>, now: Date, calendar: Calendar
    ) -> [ScheduledOccurrence] {
        occurrences(
            of: schedules, from: lookbackStart(now: now, calendar: calendar), through: LogDate(now, calendar: calendar),
            calendar: calendar
        )
        .filter { $0.instant <= now && !handled.contains($0.key) }
    }

    /// Upcoming occurrences on a day: not yet due, and not handled early.
    public static func pending(
        on date: LogDate, _ schedules: [MealSchedule], handled: Set<OccurrenceKey>, now: Date, calendar: Calendar
    ) -> [ScheduledOccurrence] {
        occurrences(of: schedules, from: date, through: date, calendar: calendar)
            .filter { $0.instant > now && !handled.contains($0.key) }
    }

    /// Notifications for upcoming occurrences of schedules that ask for one, soonest first.
    /// `describe` gives the meal name, energy and destination name; nil drops the occurrence.
    public static func notificationPlan(
        _ schedules: [MealSchedule], handled: Set<OccurrenceKey>, now: Date, calendar: Calendar, horizonDays: Int = 7,
        describe: (ScheduledOccurrence) -> (meal: String, kcal: Double?, destination: String)?
    ) -> [PlannedNotification] {
        let today = LogDate(now, calendar: calendar)
        let upcoming = occurrences(
            of: schedules.filter(\.notify), from: today, through: today.adding(days: horizonDays, calendar: calendar),
            calendar: calendar
        )
        .filter { $0.instant > now && !handled.contains($0.key) }
        return upcoming.prefix(maxNotifications).compactMap { occurrence in
            guard let info = describe(occurrence) else { return nil }
            let energy = info.kcal.map { " (\(NumberFormatting.energy($0)) kcal)" } ?? ""
            return PlannedNotification(
                id: identifier(for: occurrence.key), fireDate: occurrence.instant,
                title: "Logged \(info.meal)",
                body: "Added\(energy) to \(info.destination). Didn’t eat it? Open Instalog to remove it.")
        }
    }

    public static func identifier(for key: OccurrenceKey) -> String {
        "\(PlannedNotification.identifierPrefix)\(key.scheduleID.uuidString).\(key.date)"
    }
}
