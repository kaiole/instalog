import InstalogCore
import SwiftUI

/// What the schedule editor opens on: a new schedule (optionally prefilled) or an existing one.
enum ScheduleEditorTarget: Hashable, Identifiable {
    case new(mealID: UUID?, sectionID: UUID?)
    case edit(UUID)

    var id: String {
        switch self {
        case .new(let meal, let section): "new-\(meal?.uuidString ?? "")-\(section?.uuidString ?? "")"
        case .edit(let id): id.uuidString
        }
    }
}

enum ScheduleFormat {
    /// Calendar weekdays in display order, Monday first.
    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]
    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]

    static func letter(_ weekday: Int) -> String {
        String(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
    }

    static func date(minuteOfDay: Int) -> Date {
        Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: Date()) ?? Date()
    }

    /// "12:30 PM"
    static func time(_ schedule: MealSchedule) -> String { time(minuteOfDay: schedule.minuteOfDay) }

    static func time(minuteOfDay: Int) -> String {
        date(minuteOfDay: minuteOfDay).formatted(date: .omitted, time: .shortened)
    }

    /// "12:30", without the day period, for compact rows.
    static func clock(_ schedule: MealSchedule) -> String {
        date(minuteOfDay: schedule.minuteOfDay).formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }

    /// "AM" or "PM", where the locale uses one.
    static func period(_ schedule: MealSchedule) -> String {
        let full = time(schedule)
        let short = clock(schedule)
        return full.replacingOccurrences(of: short, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// "Every weekday", "Every day", "Weekends", "Mon, Wed and Fri", or "Once, on Sat, Oct 10".
    static func days(_ recurrence: ScheduleRecurrence) -> String {
        switch recurrence {
        case .once(let day): return "Once, on \(Format.shortDay(day))"
        case .weekly(let days):
            if days.count == 7 { return "Every day" }
            if days == weekdays { return "Every weekday" }
            if days == [1, 7] { return "Weekends" }
            let names = weekOrder.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
            return "Every " + names.formatted(.list(type: .and))
        }
    }

    /// "Daily", "M–F", "Sat", "Weekends" or "M W F", for the saved meals button.
    static func compactDays(_ recurrence: ScheduleRecurrence) -> String {
        switch recurrence {
        case .once(let day): return Format.shortDay(day)
        case .weekly(let days):
            if days.count == 7 { return "Daily" }
            if days == weekdays { return "M–F" }
            if days == [1, 7] { return "Weekends" }
            if days.count == 1, let day = days.first { return Calendar.current.shortWeekdaySymbols[day - 1] }
            return weekOrder.filter(days.contains).map(letter).joined(separator: " ")
        }
    }

    /// "Repeats weekdays", "Repeats daily", "Repeats on Mon and Thu".
    static func repeats(_ recurrence: ScheduleRecurrence) -> String {
        guard case .weekly(let days) = recurrence else { return "Once" }
        if days.count == 7 { return "Repeats daily" }
        if days == weekdays { return "Repeats weekdays" }
        if days == [1, 7] { return "Repeats on weekends" }
        let names = weekOrder.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
        return "Repeats on " + names.formatted(.list(type: .and))
    }

    static func summary(_ recurrence: ScheduleRecurrence, minuteOfDay: Int) -> String {
        "\(days(recurrence)) at \(time(minuteOfDay: minuteOfDay))"
    }
}

/// Presents the schedule editor as a sheet, styled like the app's other sheets.
extension View {
    func scheduleEditorSheet(_ model: DiaryModel, target: Binding<ScheduleEditorTarget?>) -> some View {
        sheet(item: target) { item in
            ScheduleEditorView(model: model, target: item, close: { target.wrappedValue = nil })
                .errorAlert(model)
                .presentationBackground(Palette.sheet)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
    }
}

/// Create or edit a schedule: saved meal, section, time, and which days. It logs itself then.
struct ScheduleEditorView: View {
    let model: DiaryModel
    let target: ScheduleEditorTarget
    let close: () -> Void

    private enum Mode: Hashable { case repeats, once }

    @State private var mealID: UUID?
    @State private var sectionID: UUID?
    @State private var time = ScheduleFormat.date(minuteOfDay: 12 * 60)
    @State private var mode = Mode.repeats
    @State private var days = ScheduleFormat.weekdays
    @State private var day = Date()
    @State private var notify = false
    @State private var notificationsBlocked = false
    @State private var confirmingDelete = false
    @State private var isSaving = false
    @State private var loaded = false
    @State private var newID = UUID()

    private var existing: MealSchedule? {
        if case .edit(let id) = target { return model.schedules.first { $0.id == id } }
        return nil
    }

    private var minuteOfDay: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var recurrence: ScheduleRecurrence {
        mode == .once ? .once(LogDate(day)) : .weekly(days)
    }

    /// A one-time schedule must still be ahead, or it would never log.
    private var isInPast: Bool {
        guard mode == .once else { return false }
        let draft = MealSchedule(mealTemplateID: UUID(), sectionID: nil, minuteOfDay: minuteOfDay, recurrence: recurrence)
        return ScheduleEngine.instant(of: draft, on: LogDate(day), calendar: .current) <= Date()
    }

    private var canSave: Bool {
        mealID != nil && !isSaving && !isInPast && (mode == .once || !days.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SheetHeader(title: existing == nil ? "Schedule meal" : "Edit schedule", subtitle: subtitle, close: close)
                    .padding(.bottom, Spacing.s)
                FormGroup(caption: "Meal") {
                    mealRow
                    if model.hasSections { sectionRow }
                    FormRow(label: "Time") {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Palette.accent)
                    }
                }
                repeatGroup.padding(.top, Spacing.s)
                notifyGroup.padding(.top, Spacing.s)
                Text(footnote)
                    .font(Typeface.footnote)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.top, Spacing.xs)
                VStack(spacing: Spacing.s) {
                    Button(existing == nil ? "Save schedule" : "Save", action: save)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSave)
                    if existing != nil {
                        Button { confirmingDelete = true } label: {
                            Label("Delete schedule", systemImage: "trash")
                                .font(Typeface.sans(16, .semibold, relativeTo: .headline))
                                .foregroundStyle(Palette.dangerText)
                                .frame(maxWidth: .infinity, minHeight: Metrics.button)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Palette.outline))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Spacing.l)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, 20)
            .padding(.bottom, Spacing.xxl)
        }
        .foregroundStyle(Palette.text)
        .onAppear(perform: load)
        .confirmationDialog("Delete this schedule?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete schedule", role: .destructive, action: delete)
        } message: {
            Text(deleteMessage)
        }
    }

    private var subtitle: String {
        guard let existing else { return "It logs itself at this time" }
        return "\(model.mealName(for: existing)) · \(model.destinationName(for: existing))"
    }

    private var footnote: String {
        if isInPast { return "That time has already passed. Pick a later time or day." }
        return "Logging this meal by hand never cancels the schedule. To skip one day, tap it on Today."
    }

    private var deleteMessage: String {
        guard let existing else { return "" }
        let name = model.mealName(for: existing)
        let when: String
        switch existing.recurrence {
        case .once(let day): when = "won’t log on \(Format.shortDay(day))"
        case .weekly: when = "won’t log again"
        }
        return "\(name) \(when). Meals it already logged stay in your diary."
    }

    private var mealRow: some View {
        let selected = mealID.flatMap { model.meal(id: $0) }
        return Menu {
            ForEach(model.activeMeals) { meal in
                Button(meal.name) { pick(meal) }
            }
        } label: {
            FormRow(label: "Saved meal") {
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    HStack(spacing: 6) {
                        Text(selected?.name ?? "Choose")
                            .font(Typeface.body)
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(Palette.tertiary)
                    }
                    if let selected {
                        Text("\(NumberFormatting.energy(energy(of: selected))) kcal")
                            .font(Typeface.numFootnote)
                            .foregroundStyle(Palette.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved meal, \(selected?.name ?? "none chosen")")
    }

    private var sectionRow: some View {
        let selected = sectionID.flatMap { id in model.activeSections.first { $0.id == id } }
        return Menu {
            ForEach(model.activeSections) { section in
                Button(section.name) { sectionID = section.id }
            }
        } label: {
            FormRow(label: "Section") {
                HStack(spacing: 6) {
                    Text(selected?.name ?? "Choose").font(Typeface.body).foregroundStyle(Palette.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Section, \(selected?.name ?? "none chosen")")
    }

    private var repeatGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Caption("Repeat").padding(.horizontal, Spacing.xs)
            VStack(alignment: .leading, spacing: Spacing.m) {
                SegmentedControl(options: [("Repeats", Mode.repeats), ("Once", Mode.once)], selection: $mode)
                if mode == .repeats {
                    HStack(spacing: 0) {
                        ForEach(ScheduleFormat.weekOrder, id: \.self) { weekday in
                            dayChip(weekday)
                            if weekday != ScheduleFormat.weekOrder.last { Spacer(minLength: 2) }
                        }
                    }
                    Text(days.isEmpty ? "Pick at least one day." : ScheduleFormat.summary(recurrence, minuteOfDay: minuteOfDay))
                        .font(Typeface.subhead)
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, Spacing.xs)
                } else {
                    HStack {
                        Text("Date").font(Typeface.body)
                        Spacer()
                        DatePicker("Date", selection: $day, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                            .labelsHidden()
                            .tint(Palette.accent)
                    }
                    .padding(.horizontal, Spacing.xs)
                    .frame(minHeight: 48)
                    Text("\(ScheduleFormat.summary(recurrence, minuteOfDay: minuteOfDay)). Removed after it logs.")
                        .font(Typeface.subhead)
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, Spacing.xs)
                }
            }
            .padding(Spacing.m)
            .cardBackground()
        }
    }

    private func dayChip(_ weekday: Int) -> some View {
        let isOn = days.contains(weekday)
        return Button {
            if isOn { days.remove(weekday) } else { days.insert(weekday) }
        } label: {
            Text(ScheduleFormat.letter(weekday))
                .font(Typeface.mono(14, .semibold, relativeTo: .callout))
                .foregroundStyle(isOn ? Palette.onAccent : Palette.secondary)
                .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                .background(isOn ? Palette.accent : Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var notifyGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(isOn: Binding(get: { notify }, set: setNotify)) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Notify me after it logs").font(Typeface.body)
                    Text(notificationsBlocked
                        ? "Notifications are off for Instalog. Turn them on in the Settings app, under Notifications."
                        : "A quiet notification each time it logs itself.")
                        .font(Typeface.footnote)
                        .foregroundStyle(notificationsBlocked ? Palette.over : Palette.tertiary)
                }
            }
            .tint(Palette.accent)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .cardBackground()
        }
    }

    private func setNotify(_ value: Bool) {
        notify = value
        notificationsBlocked = false
        guard value else { return }
        Task {
            if !(await ScheduleNotifier.requestAuthorization()) {
                notify = false
                notificationsBlocked = true
            }
        }
    }

    private func energy(of meal: MealTemplate) -> Double {
        let items = DraftItem.items(for: meal, foods: model.foods)
        return (try? NutritionCalculator.summarize(items.map(\.calculatorItem)))?[.energy].known ?? 0
    }

    /// Picking a meal also picks a section that offers it, when the current one doesn't.
    private func pick(_ meal: MealTemplate) {
        mealID = meal.id
        let offering = model.sections(containing: meal.id)
        if let sectionID, offering.contains(where: { $0.id == sectionID }) { return }
        if let first = offering.first { sectionID = first.id }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            mealID = existing.mealTemplateID
            sectionID = existing.sectionID
            time = ScheduleFormat.date(minuteOfDay: existing.minuteOfDay)
            notify = existing.notify
            switch existing.recurrence {
            case .weekly(let weekly):
                mode = .repeats
                days = weekly
            case .once(let date):
                mode = .once
                day = date.startOfDay()
            }
            return
        }
        guard case .new(let meal, let section) = target else { return }
        sectionID = section ?? model.currentDestination.section?.id ?? model.activeSections.first?.id
        if let meal = meal.flatMap({ model.meal(id: $0) }) ?? model.selectedMeal ?? model.activeMeals.first {
            pick(meal)
        }
    }

    private func save() {
        guard let mealID, canSave else { return }
        isSaving = true
        var schedule = existing ?? MealSchedule(
            id: newID, mealTemplateID: mealID, sectionID: nil, minuteOfDay: minuteOfDay, recurrence: recurrence)
        schedule.mealTemplateID = mealID
        schedule.sectionID = model.hasSections ? sectionID : nil
        schedule.minuteOfDay = minuteOfDay
        schedule.recurrence = recurrence
        schedule.notify = notify
        Task {
            do {
                try await model.saveSchedule(schedule)
                close()
            } catch {
                model.errorMessage = "Couldn’t save the schedule. \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func delete() {
        guard let existing else { return }
        Task {
            do {
                try await model.deleteSchedule(id: existing.id)
                close()
            } catch {
                model.errorMessage = "Couldn’t delete the schedule. \(error.localizedDescription)"
            }
        }
    }
}

/// Compact repeat days: the active ones bright, the rest dim. "Once · Sat, Oct 10" for one-offs.
struct WeekLetters: View {
    let recurrence: ScheduleRecurrence

    var body: some View {
        switch recurrence {
        case .once(let day):
            Text("Once · \(Format.shortDay(day))")
                .font(Typeface.mono(11, relativeTo: .caption2))
                .foregroundStyle(Palette.secondary)
        case .weekly(let days):
            HStack(spacing: 3) {
                ForEach(ScheduleFormat.weekOrder, id: \.self) { weekday in
                    Text(ScheduleFormat.letter(weekday))
                        .font(Typeface.mono(11, days.contains(weekday) ? .semibold : .regular, relativeTo: .caption2))
                        .foregroundStyle(days.contains(weekday) ? Palette.text : Palette.handle)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ScheduleFormat.days(recurrence))
        }
    }
}

/// Every schedule, by time of day. Tapping one edits it.
struct SchedulesView: View {
    let model: DiaryModel
    @State private var editing: ScheduleEditorTarget?

    private var schedules: [MealSchedule] {
        model.activeSchedules.sorted { ($0.minuteOfDay, model.mealName(for: $0)) < ($1.minuteOfDay, model.mealName(for: $1)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if schedules.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(schedules) { schedule in
                            if schedule.id != schedules.first?.id {
                                Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Spacing.l)
                            }
                            row(schedule)
                        }
                        Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Spacing.l)
                        Button { editing = .new(mealID: nil, sectionID: nil) } label: {
                            Label("New schedule", systemImage: "plus")
                                .font(Typeface.sans(15, .semibold))
                                .foregroundStyle(Palette.accent)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .padding(.horizontal, Spacing.l)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .cardBackground()
                    Text("Sorted by time of day. Each one logs itself at its time on the days it repeats. Logging by hand never cancels a schedule; skip a single day from Today.")
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.tertiary)
                        .padding(.horizontal, Spacing.xs)
                }
            }
            .padding(Spacing.l)
        }
        .background(Palette.sheet)
        .navigationTitle("Scheduled meals")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(Palette.text)
        .scheduleEditorSheet(model, target: $editing)
        .errorAlert(model)
    }

    private func row(_ schedule: MealSchedule) -> some View {
        let energy = model.nutrition(of: schedule)[.energy].known
        return Button { editing = .edit(schedule.id) } label: {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ScheduleFormat.clock(schedule)).font(Typeface.mono(15, .semibold, relativeTo: .body))
                    Text(ScheduleFormat.period(schedule)).font(Typeface.caption).foregroundStyle(Palette.tertiary)
                }
                .frame(minWidth: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.mealName(for: schedule)).font(Typeface.bodyMedium).lineLimit(1)
                    HStack(spacing: 4) {
                        WeekLetters(recurrence: schedule.recurrence)
                        Text("· \(model.destinationName(for: schedule))")
                            .font(Typeface.footnote)
                            .foregroundStyle(Palette.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if schedule.notify {
                    Image(systemName: "bell")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                        .accessibilityLabel("Notifies")
                }
                Text(NumberFormatting.energy(energy)).font(Typeface.numCallout).foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 10) {
                Text("No scheduled meals").font(Typeface.title3)
                Text("Pick a saved meal and a time, and it logs itself. For example, oats at 7:30 AM every weekday.")
                    .font(Typeface.sans(14, relativeTo: .subheadline))
                    .foregroundStyle(Palette.secondary)
                Button("Schedule a saved meal") { editing = .new(mealID: nil, sectionID: nil) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.activeMeals.isEmpty)
                    .padding(.top, 6)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            Text(model.activeMeals.isEmpty
                ? "Save a meal first. Schedules log one of your saved meals."
                : "You can also schedule from Saved meals, or from the ⋯ menu on a meal card.")
                .font(Typeface.footnote)
                .foregroundStyle(Palette.tertiary)
                .padding(.horizontal, Spacing.xs)
        }
    }
}

/// On a saved meals row: "Schedule" when not scheduled, otherwise its time and days.
struct ScheduleButton: View {
    let model: DiaryModel
    let meal: MealTemplate
    let open: (ScheduleEditorTarget) -> Void

    var body: some View {
        let schedules = model.schedules(for: meal.id)
        if let first = schedules.first {
            Button { open(.edit(first.id)) } label: {
                Label {
                    Text(schedules.count > 1
                        ? "\(schedules.count) times"
                        : "\(ScheduleFormat.clock(first)) · \(ScheduleFormat.compactDays(first.recurrence))")
                } icon: {
                    Image(systemName: "clock").foregroundStyle(Palette.accent)
                }
                .font(Typeface.mono(12, .medium, relativeTo: .caption))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Metrics.tapTarget)
                .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit schedule for \(meal.name): \(ScheduleFormat.summary(first.recurrence, minuteOfDay: first.minuteOfDay))")
        } else {
            Button { open(.new(mealID: meal.id, sectionID: nil)) } label: {
                Label("Schedule", systemImage: "clock.badge.plus")
                    .font(Typeface.sans(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: Metrics.tapTarget)
                    .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Palette.outline))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Schedule \(meal.name)")
        }
    }
}
