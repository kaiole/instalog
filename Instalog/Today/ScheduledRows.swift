import InstalogCore
import SwiftUI

/// A section's scheduled meals for the viewed day: upcoming ones as dashed ghost rows, skipped
/// ones faded with a way back. Neither counts toward totals.
struct ScheduledRows: View {
    let model: DiaryModel
    let destination: Destination
    let editSchedule: (UUID) -> Void
    @State private var acting: ScheduledOccurrence?

    var body: some View {
        let pending = model.pendingOccurrences(in: destination)
        let skipped = model.skippedOccurrences(in: destination)
        let rows = (pending.map { ($0, false) } + skipped.map { ($0, true) }).sorted { $0.0.instant < $1.0.instant }
        if !rows.isEmpty {
            VStack(spacing: Spacing.s) {
                ForEach(rows, id: \.0.id) { occurrence, isSkipped in
                    if isSkipped {
                        SkippedRow(model: model, occurrence: occurrence) {
                            Task { await model.unskipOccurrence(occurrence) }
                        }
                    } else {
                        GhostRow(model: model, occurrence: occurrence) { acting = occurrence }
                    }
                }
            }
            .confirmationDialog(
                dialogTitle, isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
                titleVisibility: .visible, presenting: acting
            ) { occurrence in
                if model.isViewingToday {
                    Button("Log now") { Task { await model.logOccurrenceNow(occurrence) } }
                }
                Button(model.isViewingToday ? "Skip today" : "Skip \(Format.shortDay(occurrence.key.date))") {
                    Task { await model.skipOccurrence(occurrence) }
                }
                Button("Edit schedule") { editSchedule(occurrence.schedule.id) }
            } message: { occurrence in
                Text("Scheduled for \(ScheduleFormat.time(occurrence.schedule)) in \(model.destinationName(for: occurrence.schedule)). It logs itself then; you don’t need to do anything.")
            }
        }
    }

    private var dialogTitle: String {
        guard let acting else { return "" }
        let energy = model.nutrition(of: acting.schedule)[.energy].known
        return "\(model.mealName(for: acting.schedule)) · \(NumberFormatting.energy(energy)) kcal"
    }
}

/// A scheduled meal that hasn't logged yet. Dashed, like everything not yet real.
struct GhostRow: View {
    let model: DiaryModel
    let occurrence: ScheduledOccurrence
    let open: () -> Void

    var body: some View {
        let schedule = occurrence.schedule
        let energy = model.nutrition(of: schedule)[.energy].known
        Button(action: open) {
            HStack(spacing: Spacing.m) {
                ClockTile(time: ScheduleFormat.clock(schedule))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.mealName(for: schedule))
                        .font(Typeface.bodyMedium)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    Text(detail)
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(NumberFormatting.energy(energy))
                    .font(Typeface.numCallout)
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.leading, Spacing.s)
            .padding(.trailing, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 56)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(Palette.handle, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.mealName(for: schedule)), scheduled for \(ScheduleFormat.time(schedule)), \(NumberFormatting.energy(energy)) calories, not counted yet")
        .accessibilityHint("Shows Log now, Skip and Edit schedule")
    }

    private var detail: String {
        let at = "logs itself at \(ScheduleFormat.time(occurrence.schedule))"
        if model.isViewingFuture, case .weekly = occurrence.schedule.recurrence {
            return "\(ScheduleFormat.repeats(occurrence.schedule.recurrence)) · \(at)"
        }
        return "Scheduled · \(at)"
    }
}

/// A scheduled meal skipped for this day. Tapping brings it back.
struct SkippedRow: View {
    let model: DiaryModel
    let occurrence: ScheduledOccurrence
    let unskip: () -> Void

    var body: some View {
        let schedule = occurrence.schedule
        Button(action: unskip) {
            HStack(spacing: Spacing.m) {
                ClockTile(time: ScheduleFormat.clock(schedule))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.mealName(for: schedule))
                        .font(Typeface.bodyMedium)
                        .strikethrough()
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                    Text("Skipped · won’t log \(model.isViewingToday ? "today" : "this day")")
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
                Text("Un-skip")
                    .font(Typeface.calloutStrong)
                    .foregroundStyle(Palette.accent)
            }
            .padding(.leading, Spacing.s)
            .padding(.trailing, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 56)
            .opacity(0.85)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.mealName(for: schedule)), skipped \(model.isViewingToday ? "today" : "on this day")")
        .accessibilityHint(occurrence.instant <= Date() ? "Brings it back. Its time has passed, so it logs right away." : "Brings it back")
    }
}

/// The scheduled time on a control tile with a small clock.
struct ClockTile: View {
    let time: String

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
            Text(time).font(Typeface.mono(12, .semibold, relativeTo: .caption))
        }
        .foregroundStyle(Palette.secondary)
        .frame(width: 48, height: 40)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityHidden(true)
    }
}
