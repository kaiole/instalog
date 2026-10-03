import InstalogCore
import SwiftUI

/// Jump to any section. Shows what was logged where; nothing is ever marked done.
struct SectionsSheet: View {
    let model: DiaryModel
    let close: () -> Void
    let editRoutine: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                SheetHeader(title: "Sections", close: close)
                Text("Jump anywhere. Sections stay open all day, and nothing gets checked off.")
                    .font(Typeface.sans(13, relativeTo: .footnote))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                ForEach(Array(model.destinations.enumerated()), id: \.element.id) { index, destination in
                    row(index: index, destination: destination)
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
                .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .foregroundStyle(Palette.text)
    }

    private func row(index: Int, destination: Destination) -> some View {
        let entries = model.entries(in: destination)
        let energy = NutritionCalculator.summarize(entries: entries)[.energy].known
        let isCurrent = destination.id == model.currentDestination.id
        var detail = entries.isEmpty ? "Nothing logged" : "\(entries.count) logged · \(NumberFormatting.energy(energy)) kcal"
        if let section = destination.section, section.mode == .all { detail += " · shows all meals" }

        return Button {
            model.selectDestination(id: destination.id)
            close()
        } label: {
            HStack(spacing: 14) {
                Text(String(format: "%02d", index + 1))
                    .font(Typeface.mono(13))
                    .foregroundStyle(Palette.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name)
                        .font(Typeface.sans(17, .semibold, relativeTo: .headline))
                    Text(detail).font(Typeface.sans(13, relativeTo: .footnote)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("Here now")
                        .font(Typeface.sans(12, .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.accentBorder))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(isCurrent ? Palette.badge : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(destination.name). \(detail)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Go to a day: tap a date to open it. Days with entries are dotted; future days can't be chosen.
struct DayPickerSheet: View {
    let model: DiaryModel
    let close: () -> Void
    @State private var month = LogDate(year: 1970, month: 1, day: 1)
    @State private var logged: Set<LogDate> = []

    private var calendar: Calendar { model.calendar }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(title: "Go to day", subtitle: "Tap a day to open it", close: close)
                HStack(spacing: Spacing.s) {
                    Button("Today") { go(to: model.today) }
                        .buttonStyle(ChipButtonStyle(isSelected: model.isViewingToday))
                    Button("Yesterday") { go(to: model.today.adding(days: -1, calendar: calendar)) }
                        .buttonStyle(ChipButtonStyle(isSelected: model.viewedDate == model.today.adding(days: -1, calendar: calendar)))
                }
                .padding(.top, Spacing.xs)
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
                        .disabled(!canShowNextMonth)
                        .accessibilityLabel("Next month")
                }
                monthGrid
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4)
                    Text("has entries").font(Typeface.footnote).foregroundStyle(Palette.secondary)
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
        return LazyVGrid(columns: columns, spacing: Spacing.xs) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(Typeface.caption).foregroundStyle(Palette.tertiary).accessibilityHidden(true)
            }
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: Metrics.tapTarget) }
            ForEach(1...count, id: \.self) { day in
                dayCell(LogDate(year: month.year, month: month.month, day: day))
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
                .foregroundStyle(isSelected ? Palette.onAccent : isFuture ? Palette.disabled : Palette.text)
                .frame(maxWidth: .infinity, minHeight: Metrics.tapTarget)
                .background(isSelected ? Palette.accent : .clear, in: shape)
                .overlay(shape.strokeBorder(isToday && !isSelected ? Palette.accent : .clear, lineWidth: 1.5))
                .overlay(alignment: .bottom) {
                    if hasEntries {
                        Circle().fill(isSelected ? Palette.onAccent : Palette.accent).frame(width: 4, height: 4).padding(.bottom, 5)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(
            date.startOfDay(in: calendar).formatted(date: .complete, time: .omitted)
                + (isToday ? ", today" : "") + (hasEntries ? ", has entries" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var canShowNextMonth: Bool { lastOfMonth(month) < model.today }

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
