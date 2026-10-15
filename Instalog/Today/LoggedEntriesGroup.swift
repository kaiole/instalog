import InstalogCore
import SwiftUI
import UIKit

/// Entries logged in the current section. Shown expanded; the header collapses them.
/// Tapping an entry opens it inline for editing, so the rest of the day stays in view.
struct LoggedEntriesGroup: View {
    let model: DiaryModel
    let entries: [LoggedEntry]
    let sectionName: String
    /// Shown when nothing is logged; nil shows nothing.
    let emptyText: String?
    @Binding var isExpanded: Bool
    @Binding var revealedEntryID: UUID?
    /// Runs the action, first asking to save or discard any unsaved entry edit.
    let guardEdit: (@escaping () -> Void) -> Void

    var body: some View {
        if entries.isEmpty {
            if let emptyText {
                Text(emptyText)
                    .font(Typeface.subhead)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                            .strokeBorder(Palette.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        } else {
            VStack(spacing: 0) {
                summaryButton
                if isExpanded {
                    ForEach(entries) { entry in
                        if let edit = model.entryEdit, edit.original.id == entry.id {
                            ExpandedEntry(model: model, edit: edit, collapse: { collapse() })
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                                .transition(.opacity)
                        } else {
                            Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Spacing.l)
                            LoggedEntryRow(
                                model: model, entry: entry, isRevealed: revealedEntryID == entry.id,
                                reveal: { revealedEntryID = $0 ? entry.id : nil },
                                open: {
                                    if revealedEntryID != nil {
                                        revealedEntryID = nil
                                    } else {
                                        guardEdit { withAnimation(.snappy) { model.beginEditing(entry) } }
                                    }
                                })
                        }
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
            let toggle = {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                    revealedEntryID = nil
                    model.endEditing()
                }
            }
            if isExpanded, model.entryEdit != nil { guardEdit(toggle) } else { toggle() }
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

    private func collapse() {
        guardEdit { withAnimation(.snappy) { model.endEditing() } }
    }
}

/// One logged entry. Swiping left reveals Delete, which deletes on tap. Undo is in the toast.
struct LoggedEntryRow: View {
    let model: DiaryModel
    let entry: LoggedEntry
    let isRevealed: Bool
    let reveal: (Bool) -> Void
    let open: () -> Void

    @State private var dragOffset: CGFloat = 0
    private let actionWidth: CGFloat = 88

    var body: some View {
        let energy = NutritionCalculator.summarize(entry)[.energy]
        let offset = trailingSwipeOffset(revealed: isRevealed, drag: dragOffset, width: actionWidth)

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
            // A tap gesture rather than a Button: a Button would also fire at the end of a swipe,
            // opening the sheet over a row that was just deleted.
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
                    Image(systemName: "chevron.down")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(.leading, Spacing.l)
                .padding(.trailing, Spacing.m)
                .padding(.vertical, 6)
                .frame(minHeight: Metrics.formRow)
                .background(Palette.raised)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
            .offset(x: offset)
            .animation(.easeOut(duration: 0.2), value: isRevealed)
        }
        .clipped()
        .horizontalSwipe(onChanged: { dragOffset = $0 }) { translation in
            let final = (isRevealed ? -actionWidth : 0) + translation
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = 0
                reveal(final < -actionWidth / 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityLabel("\(entry.name), logged \(Format.time(entry.recordedAt)), \(NumberFormatting.energy(energy.known)) calories")
        .accessibilityHint("Opens the entry to edit amounts")
        .accessibilityAction(named: "Delete", delete)
    }

    private func delete() {
        reveal(false)
        Task { await model.deleteEntry(entry) }
    }

    private var subtitle: String {
        var parts = [Format.time(entry.recordedAt)]
        if entry.scheduleOccurrence != nil { parts.append("scheduled") }
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

/// A logged entry opened inline. Amount changes and removed foods stay a preview, mirrored in
/// the summary at the top, until Save. Everything else is in the ⋯ menu.
struct ExpandedEntry: View {
    let model: DiaryModel
    let edit: EntryEdit
    let collapse: () -> Void

    @State private var renaming = false
    @State private var newName = ""
    @State private var savingAsMeal = false
    @State private var newMealName = ""
    @State private var isSaving = false
    @State private var justSaved = false

    private var entry: LoggedEntry { edit.draft }

    var body: some View {
        let nutrition = NutritionCalculator.summarize(edit.draft)
        let saved = NutritionCalculator.summarize(edit.original)
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(NumberFormatting.energy(nutrition[.energy].known)).font(Typeface.numLarge)
                Text("kcal").font(Typeface.subhead).foregroundStyle(Palette.secondary)
                if edit.hasChanges {
                    Text(NumberFormatting.energy(saved[.energy].known))
                        .font(Typeface.mono(13, relativeTo: .subheadline))
                        .foregroundStyle(Palette.tertiary)
                        .strikethrough()
                        .accessibilityLabel("was \(NumberFormatting.energy(saved[.energy].known))")
                }
                Spacer(minLength: Spacing.s)
                MacroLine(nutrition: nutrition)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, Spacing.s)
            ForEach(edit.draft.foods) { food in
                DraftItemRow(
                    item: draftItem(food), defaultWord: "was",
                    setQuantity: { model.setEditQuantity($0, for: food.id) },
                    showsEnergyWhenAdjusted: true)
                .padding(.leading, Spacing.m)
                .padding(.trailing, Spacing.s)
                // The last food can't be removed; delete the entry instead.
                .swipeAction("Remove", isEnabled: edit.draft.foods.count > 1) {
                    withAnimation(.snappy) { model.removeEditFood(food.id) }
                }
            }
            footer
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.m)
        }
        .background(Palette.raised, in: shape)
        .overlay(shape.strokeBorder(Palette.accentBorder, lineWidth: 1.5))
        .clipShape(shape)
        .alert("Rename entry", isPresented: $renaming) {
            TextField("Entry name", text: $newName)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save as a meal", isPresented: $savingAsMeal) {
            TextField("Meal name", text: $newMealName)
            Button("Save") { Task { await saveAsMeal() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a saved meal from these foods and amounts. This entry stays as logged.")
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Button(action: collapse) {
                HStack(spacing: Spacing.s) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(Typeface.headline)
                            .multilineTextAlignment(.leading)
                        stateLine
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name), \(stateText)")
            .accessibilityHint("Closes the entry")
            menu
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, 6)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var stateLine: some View {
        if edit.hasChanges {
            StateTag(text: "Unsaved changes") {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
            }
        } else if justSaved {
            StateTag(text: "Saved") {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            }
        } else {
            Text(meta).font(Typeface.footnote).foregroundStyle(Palette.tertiary)
        }
    }

    private var stateText: String {
        edit.hasChanges ? "unsaved changes" : justSaved ? "saved" : meta
    }

    private var meta: String {
        var parts = [Format.time(edit.original.recordedAt)]
        if edit.original.isOneOff {
            parts.append("one-off")
        } else if edit.original.isAdjusted {
            parts.append("adjusted")
        }
        return parts.joined(separator: " · ")
    }

    private var menu: some View {
        Menu {
            Button { newName = entry.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            Menu {
                ForEach(moveTargets, id: \.id) { destination in
                    Button(destination.name) { Task { await move(to: destination) } }
                }
            } label: {
                Label(edit.hasChanges ? "Save & move to section" : "Move to section", systemImage: "arrow.right.square")
            }
            if edit.original.isOneOff {
                Button { newMealName = entry.name; savingAsMeal = true } label: {
                    Label("Save as meal…", systemImage: "bookmark")
                }
            }
            Divider()
            Button(role: .destructive) { Task { await model.deleteEntry(edit.original) } } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .accessibilityLabel("More for \(entry.name)")
        .disabled(isSaving)
    }

    @ViewBuilder
    private var footer: some View {
        if edit.hasChanges {
            HStack(spacing: Spacing.s) {
                Button("Discard") { withAnimation(.snappy) { model.discardEntryEdit() } }
                    .buttonStyle(InlineActionButtonStyle(prominent: false))
                    .frame(maxWidth: 120)
                Button("Save", action: save)
                    .buttonStyle(InlineActionButtonStyle(prominent: true))
            }
            .disabled(isSaving)
        } else if edit.draft.foods.count > 1 {
            Label("Swipe a food left to remove it.", systemImage: "info.circle")
                .font(Typeface.footnote)
                .foregroundStyle(Palette.tertiary)
        }
    }

    /// Every active section except the current one, plus the Daily log for a sectioned entry.
    private var moveTargets: [Destination] {
        var targets = model.activeSections.filter { $0.id != edit.original.sectionID }.map { Destination(section: $0) }
        if edit.original.sectionID != nil { targets.append(Destination(section: nil)) }
        return targets
    }

    private func draftItem(_ food: LoggedFoodSnapshot) -> DraftItem {
        let saved = edit.original.foods.first { $0.id == food.id }?.quantity
        return DraftItem(
            id: food.id, food: food.asFoodDefinition, quantity: food.quantity, unit: food.unit, templateQuantity: saved)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await model.saveEntryEdit()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.snappy) { justSaved = true }
                try? await Task.sleep(for: .seconds(1.2))
                // Close only if nothing changed again meanwhile.
                if model.entryEdit?.original.id == edit.original.id, model.entryEdit?.hasChanges == false {
                    withAnimation(.snappy) { model.endEditing() }
                }
            } catch EntryValidationError.noFoods {
                model.errorMessage = "An entry needs at least one food with an amount above zero. To remove it, delete the entry."
            } catch {
                model.errorMessage = "Couldn’t save changes. \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func rename() async {
        do {
            try await model.renameEntry(edit.original, to: newName)
        } catch {
            model.errorMessage = "Couldn’t rename the entry. \(error.localizedDescription)"
        }
    }

    /// With unsaved changes, the menu item says it saves them too.
    private func move(to destination: Destination) async {
        do {
            if edit.hasChanges {
                var moved = edit.draft
                moved.assign(to: destination)
                try await model.updateEntry(moved)
                model.endEditing()
            } else {
                try await model.moveEntry(edit.original, to: destination)
            }
        } catch {
            model.errorMessage = "Couldn’t move the entry. \(error.localizedDescription)"
        }
    }

    private func saveAsMeal() async {
        let foods = edit.draft.foods.filter { $0.quantity > 0 }
        let definitions = foods.map(\.asFoodDefinition)
        let meal = MealTemplate(
            name: newMealName,
            items: zip(foods, definitions).map { snapshot, food in
                MealTemplateItem(foodID: food.id, defaultQuantity: snapshot.quantity, unit: snapshot.unit)
            },
            sortOrder: 0)
        do {
            try await model.saveMeal(meal, foods: definitions.filter { model.foods[$0.id] == nil })
            model.toast = Toast(message: "Saved “\(meal.name)” as a meal", undo: nil)
        } catch {
            model.errorMessage = "Couldn’t save the meal. \(error.localizedDescription)"
        }
    }
}

/// "Unsaved changes" / "Saved": lime text on the accent surface.
private struct StateTag<Icon: View>: View {
    let text: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 5) {
            icon()
            Text(text).font(Typeface.sans(12, .semibold, relativeTo: .caption))
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Palette.accentSurface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Palette.accentBorder))
    }
}

/// 44 pt Save / Discard inside a card: lime when prominent, control fill otherwise.
private struct InlineActionButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.calloutStrong)
            .foregroundStyle(prominent ? Palette.onAccent : Palette.text)
            .frame(maxWidth: .infinity, minHeight: Metrics.tapTarget)
            .background(prominent ? Palette.accent : Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
