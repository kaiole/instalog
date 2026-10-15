import InstalogCore
import SwiftUI

/// The day at a glance: every section with what's logged there and what's scheduled to come.
/// Tapping a section jumps to it. Nothing is ever marked done.
struct SectionsSheet: View {
    let model: DiaryModel
    let close: () -> Void
    let editRoutine: () -> Void

    var body: some View {
        let overview = model.dayOverview
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SheetHeader(title: "Sections", subtitle: subtitle(overview), close: close)
                    .padding(.bottom, Spacing.s)
                ForEach(Array(overview.enumerated()), id: \.element.id) { index, section in
                    SectionOverviewCard(
                        model: model, index: index, section: section,
                        isCurrent: section.id == model.currentDestination.id
                    ) {
                        model.selectDestination(id: section.id)
                        close()
                    }
                }
                Button(action: editRoutine) {
                    HStack {
                        Text("Edit sections & meals")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Palette.tertiary)
                    }
                    .font(Typeface.sans(15, .medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.outline))
                }
                .buttonStyle(.plain)
                .padding(.top, Spacing.xs)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .foregroundStyle(Palette.text)
    }

    /// "Mon, Oct 5 · 1,680 kcal eaten · tap to jump"
    private func subtitle(_ overview: [SectionOverview]) -> String {
        let eaten = overview.reduce(0) { $0 + $1.loggedEnergy }
        let word = model.isViewingFuture ? "planned" : "eaten"
        let total = eaten > 0 ? "\(NumberFormatting.energy(eaten)) kcal \(word)" : "nothing \(word) yet"
        return "\(Format.shortDay(model.viewedDate)) · \(total) · tap to jump"
    }
}

/// One section in the overview: one card, one button.
private struct SectionOverviewCard: View {
    let model: DiaryModel
    let index: Int
    let section: SectionOverview
    let isCurrent: Bool
    let jump: () -> Void

    /// Long sections show their first few entries and a count of the rest.
    private static let maxRows = 4

    var body: some View {
        let entries = section.entries
        let shown = entries.count > Self.maxRows ? Array(entries.prefix(Self.maxRows - 1)) : entries
        let hidden = entries.dropFirst(shown.count)
        Button(action: jump) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                header
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { entry in
                        line(entry.name, energy: NutritionCalculator.summarize(entry)[.energy].known)
                    }
                    if !hidden.isEmpty {
                        line(
                            "+ \(hidden.count) more",
                            energy: NutritionCalculator.summarize(entries: Array(hidden))[.energy].known, muted: true)
                    }
                    ForEach(section.scheduled) { occurrence in
                        scheduledLine(occurrence, skipped: false)
                    }
                    ForEach(section.skipped) { occurrence in
                        scheduledLine(occurrence, skipped: true)
                    }
                    if entries.isEmpty, section.scheduled.isEmpty, section.skipped.isEmpty {
                        Text(model.isViewingFuture ? "Nothing planned" : "Nothing logged")
                            .font(Typeface.footnote)
                            .foregroundStyle(Palette.tertiary)
                            .frame(minHeight: 26)
                    }
                }
                .padding(.leading, 34)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Palette.badge : Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Goes to this section")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", index + 1))
                .font(Typeface.mono(13))
                .foregroundStyle(Palette.tertiary)
                .frame(width: 20, alignment: .leading)
            HStack(spacing: Spacing.s) {
                Text(section.destination.name)
                    .font(Typeface.sans(17, .semibold, relativeTo: .headline))
                if isCurrent {
                    Text("Here now")
                        .font(Typeface.sans(12, .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.accentBorder))
                }
            }
            Spacer(minLength: Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                (Text(NumberFormatting.energy(section.loggedEnergy))
                    .font(Typeface.mono(15, .semibold, relativeTo: .body))
                    .foregroundStyle(section.loggedEnergy > 0 ? Palette.text : Palette.tertiary)
                    + Text(" kcal").font(Typeface.footnote).foregroundStyle(Palette.tertiary))
                if section.scheduledEnergy > 0 {
                    Text("+\(NumberFormatting.energy(section.scheduledEnergy)) sched.")
                        .font(Typeface.mono(11, relativeTo: .caption2))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private func line(_ name: String, energy: Double, muted: Bool = false) -> some View {
        HStack(spacing: Spacing.s) {
            Text(name)
                .font(Typeface.subhead)
                .foregroundStyle(muted ? Palette.tertiary : Palette.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.s)
            Text(NumberFormatting.energy(energy))
                .font(Typeface.numFootnote)
                .foregroundStyle(Palette.tertiary)
        }
        .frame(minHeight: 26)
    }

    private func scheduledLine(_ occurrence: ScheduledOccurrence, skipped: Bool) -> some View {
        let schedule = occurrence.schedule
        return HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
            Text(ScheduleFormat.clock(schedule)).font(Typeface.numFootnote)
            Text(model.mealName(for: schedule))
                .font(Typeface.subhead)
                .strikethrough(skipped)
                .lineLimit(1)
            Spacer(minLength: Spacing.s)
            Text(skipped ? "skipped" : NumberFormatting.energy(model.nutrition(of: schedule)[.energy].known))
                .font(Typeface.numFootnote)
        }
        .foregroundStyle(Palette.tertiary)
        .frame(minHeight: 26)
    }

    private var accessibilityText: String {
        var parts = ["\(section.destination.name)"]
        if section.entries.isEmpty {
            parts.append("nothing logged")
        } else {
            parts.append("\(section.entries.count) logged, \(NumberFormatting.energy(section.loggedEnergy)) calories")
            parts.append(section.entries.map(\.name).formatted(.list(type: .and)))
        }
        for occurrence in section.scheduled {
            parts.append("\(model.mealName(for: occurrence.schedule)) scheduled at \(ScheduleFormat.time(occurrence.schedule))")
        }
        for occurrence in section.skipped {
            parts.append("\(model.mealName(for: occurrence.schedule)) skipped")
        }
        return parts.joined(separator: ". ")
    }
}

/// Go to a day, past or future: tap a date to open it. Logged days get a dot; future days with
/// entries get a hollow ring, since they're planned rather than eaten.
struct DayPickerSheet: View {
    let model: DiaryModel
    let close: () -> Void
    @State private var month = LogDate(year: 1970, month: 1, day: 1)
    @State private var logged: Set<LogDate> = []

    private var calendar: Calendar { model.calendar }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(title: "Go to day", subtitle: "Tap a day to open it", close: close) {
                    // Only offered away from today; the arrows on the main screen cover yesterday.
                    if !model.isViewingToday {
                        Button("Today") { go(to: model.today) }
                            .buttonStyle(TodayJumpButtonStyle())
                            .accessibilityLabel(
                                "Go to today, \(model.today.startOfDay(in: calendar).formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                    }
                }
                HStack(spacing: Spacing.xs) {
                    Text(month.startOfDay(in: calendar).formatted(.dateTime.month(.wide).year()))
                        .font(Typeface.sans(17, .semibold, relativeTo: .headline))
                        .padding(.leading, Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Previous month")
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Next month")
                }
                monthGrid
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4)
                    Text("Logged").font(Typeface.footnote).foregroundStyle(Palette.secondary)
                    Circle().strokeBorder(Palette.accent, lineWidth: 1.25).frame(width: 6, height: 6)
                        .padding(.leading, Spacing.s)
                    Text("Planned").font(Typeface.footnote).foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, Spacing.xs)
                .accessibilityHidden(true)
            }
            .padding(Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Palette.text)
        .onAppear { month = firstOfMonth(model.viewedDate) }
        .task(id: month) {
            guard month.year > 1970 else { return }
            logged = await model.daysWithEntries(from: month, through: lastOfMonth(month))
        }
    }

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let weekdays = Array(symbols[first...] + symbols[..<first])
        let leading = (calendar.component(.weekday, from: month.startOfDay(in: calendar)) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month.startOfDay(in: calendar))?.count ?? 30
        // Every cell needs an id unique within its grid, or SwiftUI silently drops the duplicates:
        // blanks use negative ids, days use 1...count.
        return VStack(spacing: Spacing.xs) {
            LazyVGrid(columns: columns, spacing: Spacing.xs) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(Typeface.caption).foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: columns, spacing: Spacing.xs) {
                ForEach(-leading..<0, id: \.self) { _ in Color.clear.frame(height: Metrics.tapTarget) }
                ForEach(1...count, id: \.self) { day in
                    dayCell(LogDate(year: month.year, month: month.month, day: day))
                }
            }
        }
    }

    private func dayCell(_ date: LogDate) -> some View {
        let isSelected = date == model.viewedDate
        let isToday = date == model.today
        let isFuture = date > model.today
        let hasEntries = logged.contains(date)
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        return Button { go(to: date) } label: {
            Text("\(date.day)")
                .font(Typeface.mono(15, isSelected ? .semibold : .regular, relativeTo: .body))
                .foregroundStyle(isSelected ? Palette.onAccent : isFuture ? Palette.secondary : Palette.text)
                .frame(maxWidth: .infinity, minHeight: Metrics.tapTarget)
                .background(isSelected ? Palette.accent : .clear, in: shape)
                .overlay(shape.strokeBorder(isToday && !isSelected ? Palette.accent : .clear, lineWidth: 1.5))
                .overlay(alignment: .bottom) {
                    if hasEntries {
                        let color = isSelected ? Palette.onAccent : Palette.accent
                        Group {
                            if isFuture {
                                Circle().strokeBorder(color, lineWidth: 1.25).frame(width: 6, height: 6)
                            } else {
                                Circle().fill(color).frame(width: 4, height: 4)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            date.startOfDay(in: calendar).formatted(date: .complete, time: .omitted)
                + (isToday ? ", today" : "") + (hasEntries ? (isFuture ? ", has planned entries" : ", has entries") : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func go(to date: LogDate) {
        Task {
            await model.changeDate(to: date)
            close()
        }
    }

    private func shiftMonth(_ step: Int) {
        let shifted = calendar.date(byAdding: .month, value: step, to: month.startOfDay(in: calendar)) ?? month.startOfDay(in: calendar)
        month = firstOfMonth(LogDate(shifted, calendar: calendar))
    }

    private func firstOfMonth(_ date: LogDate) -> LogDate { LogDate(year: date.year, month: date.month, day: 1) }

    private func lastOfMonth(_ date: LogDate) -> LogDate {
        let count = calendar.range(of: .day, in: .month, for: date.startOfDay(in: calendar))?.count ?? 28
        return LogDate(year: date.year, month: date.month, day: count)
    }
}


/// "Today" beside the sheet's Close: control fill, lime text.
private struct TodayJumpButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.calloutStrong)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.tapTarget)
            .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
