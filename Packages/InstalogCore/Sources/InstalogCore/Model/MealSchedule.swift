import Foundation

/// Which days a schedule falls on.
public enum ScheduleRecurrence: Hashable, Sendable, Codable {
    /// Every week on these `Calendar` weekdays (1 = Sunday … 7 = Saturday).
    case weekly(Set<Int>)
    /// A single day.
    case once(LogDate)
}

/// A saved meal that logs itself into a section at a time of day. Before its time it's shown as
/// upcoming and never counted; once the time passes it becomes an ordinary logged entry.
public struct MealSchedule: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var mealTemplateID: UUID
    /// The section it logs into; nil logs to the unsectioned daily log.
    public var sectionID: UUID?
    /// Minutes after local midnight, 0..<1440.
    public var minuteOfDay: Int
    public var recurrence: ScheduleRecurrence
    /// Post a notification when the meal is logged.
    public var notify: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Occurrences before this moment never log: nothing is created for times before the schedule
    /// existed or was last edited.
    public var activeFrom: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(), mealTemplateID: UUID, sectionID: UUID?, minuteOfDay: Int, recurrence: ScheduleRecurrence,
        notify: Bool = false, createdAt: Date = Date(), updatedAt: Date? = nil, activeFrom: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.mealTemplateID = mealTemplateID
        self.sectionID = sectionID
        self.minuteOfDay = minuteOfDay
        self.recurrence = recurrence
        self.notify = notify
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.activeFrom = activeFrom ?? createdAt
        self.archivedAt = archivedAt
    }

    public var isArchived: Bool { archivedAt != nil }
    public var hour: Int { minuteOfDay / 60 }
    public var minute: Int { minuteOfDay % 60 }

    public func validate() throws {
        guard (0..<1440).contains(minuteOfDay) else { throw ScheduleValidationError.invalidTime }
        if case .weekly(let days) = recurrence {
            guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { throw ScheduleValidationError.noDays }
        }
    }
}

public enum ScheduleValidationError: Error, Equatable, Sendable {
    case invalidTime
    case noDays
    case mealUnavailable
}

/// One day's instance of a schedule. A schedule happens at most once per day.
public struct OccurrenceKey: Hashable, Sendable, Codable {
    public var scheduleID: UUID
    public var date: LogDate

    public init(scheduleID: UUID, date: LogDate) {
        self.scheduleID = scheduleID
        self.date = date
    }
}

public enum OccurrenceOutcome: Hashable, Sendable, Codable {
    case logged(entryID: UUID)
    case skipped
}

/// What happened to an occurrence. Once recorded, the occurrence never logs again, even if the
/// entry is later deleted.
public struct OccurrenceRecord: Hashable, Sendable, Codable {
    public var key: OccurrenceKey
    public var outcome: OccurrenceOutcome
    public var handledAt: Date

    public init(key: OccurrenceKey, outcome: OccurrenceOutcome, handledAt: Date) {
        self.key = key
        self.outcome = outcome
        self.handledAt = handledAt
    }
}

/// A computed occurrence: a schedule on a day, at its local time.
public struct ScheduledOccurrence: Hashable, Sendable, Identifiable {
    public var key: OccurrenceKey
    public var schedule: MealSchedule
    public var instant: Date

    public var id: OccurrenceKey { key }
}
