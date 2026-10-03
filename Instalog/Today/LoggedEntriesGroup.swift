import InstalogCore
import SwiftUI

/// Entries logged in the current section. Shown expanded; the header collapses them.
struct LoggedEntriesGroup: View {
    let model: DiaryModel
    let entries: [LoggedEntry]
    let sectionName: String
    let emptyText: String
    @Binding var isExpanded: Bool
    @Binding var revealedEntryID: UUID?
    let open: (LoggedEntry) -> Void

    var body: some View {
        if entries.isEmpty {
            Text(emptyText)
                .font(Typeface.subhead)
                .foregroundStyle(Palette.tertiary)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                        .strokeBorder(Palette.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else {
            VStack(spacing: 0) {
                summaryButton
                if isExpanded {
                    ForEach(entries) { entry in
                        Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Spacing.l)
                        LoggedEntryRow(
                            model: model, entry: entry, isRevealed: revealedEntryID == entry.id,
                            reveal: { revealedEntryID = $0 ? entry.id : nil },
                            open: {
                                if revealedEntryID != nil {
                                    revealedEntryID = nil
                                } else {
                                    open(entry)
                                }
                            })
                    }
                }
            }
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
    }

    private var summaryButton: some View {
        let energy = NutritionCalculator.summarize(entries: entries)[.energy]
        return Button {
            withAnimation(.snappy) {
                isExpanded.toggle()
                revealedEntryID = nil
            }
        } label: {
            HStack(spacing: Spacing.s) {
                Caption("Logged in \(sectionName)")
                    .lineLimit(1)
                Text("\(entries.count)")
                    .font(Typeface.mono(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Palette.badge, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                Spacer(minLength: Spacing.s)
                Text("\(NumberFormatting.energy(energy.known)) kcal")
                    .font(Typeface.mono(13, relativeTo: .subheadline))
                    .foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.up")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
            }
            .padding(.leading, Spacing.l)
            .padding(.trailing, Spacing.m)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entries.count) logged here, \(NumberFormatting.energy(energy.known)) calories")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides entries" : "Shows entries")
    }
}

/// One logged entry. Swiping left reveals Delete; a long swipe deletes. Undo is in the toast.
struct LoggedEntryRow: View {
    let model: DiaryModel
    let entry: LoggedEntry
    let isRevealed: Bool
    let reveal: (Bool) -> Void
    let open: () -> Void

    @GestureState private var dragOffset: CGFloat = 0
    private let actionWidth: CGFloat = 88
    private let fullSwipe: CGFloat = 200

    var body: some View {
        let energy = NutritionCalculator.summarize(entry)[.energy]
        let offset = min(0, max(-fullSwipe - 20, (isRevealed ? -actionWidth : 0) + dragOffset))

        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button(role: .destructive, action: delete) {
                    VStack(spacing: 3) {
                        Image(systemName: "trash")
                        Text("Delete").font(Typeface.sans(12, .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(Palette.onDanger)
                    .frame(width: max(actionWidth, -offset))
                    .frame(maxHeight: .infinity)
                    .background(Palette.danger)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            Button(action: open) {
                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(Typeface.bodyMedium)
                        Text(subtitle)
                            .font(Typeface.footnote)
                            .foregroundStyle(Palette.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text(NumberFormatting.energy(energy.known))
                        .font(Typeface.numCallout)
                        .foregroundStyle(Palette.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(.leading, Spacing.l)
                .padding(.trailing, Spacing.m)
                .padding(.vertical, 6)
                .frame(minHeight: Metrics.formRow)
                .background(Palette.raised)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: offset)
            .animation(.easeOut(duration: 0.2), value: isRevealed)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .updating($dragOffset) { value, state, _ in
                    if abs(value.translation.width) > abs(value.translation.height) {
                        state = value.translation.width
                    }
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let final = (isRevealed ? -actionWidth : 0) + value.translation.width
                    if final < -fullSwipe {
                        delete()
                    } else {
                        reveal(final < -actionWidth / 2)
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), logged \(Format.time(entry.recordedAt)), \(NumberFormatting.energy(energy.known)) calories")
        .accessibilityHint("Opens the entry")
        .accessibilityAction(named: "Delete", delete)
    }

    private func delete() {
        reveal(false)
        Task { await model.deleteEntry(entry) }
    }

    private var subtitle: String {
        var parts = [Format.time(entry.recordedAt)]
        if entry.isOneOff {
            parts.append("one-off")
        } else if entry.isAdjusted {
            parts.append("adjusted")
        }
        if model.currentDestination.isUnsectioned, model.hasSections, entry.sectionID != nil {
            parts.append("from \(model.destinationName(for: entry))")
        }
        return parts.joined(separator: " · ")
    }
}
