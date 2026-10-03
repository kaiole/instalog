import InstalogCore
import SwiftUI

/// Inspect and edit one logged entry. Edits apply to a copy and are saved together on Done;
/// closing without Done discards them. The originating saved meal never changes.
struct EntrySheet: View {
    let model: DiaryModel
    let original: LoggedEntry
    let close: () -> Void

    @State private var draft: LoggedEntry
    @State private var confirmingDiscard = false
    @State private var savingAsMeal = false
    @State private var newMealName = ""
    @State private var isSaving = false

    init(model: DiaryModel, original: LoggedEntry, close: @escaping () -> Void) {
        self.model = model
        self.original = original
        self.close = close
        _draft = State(initialValue: original)
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        let nutrition = NutritionCalculator.summarize(draft)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: "Edit entry",
                subtitle: "\(Format.dayHeading(draft.logDate, today: model.today)) · \(Format.time(draft.recordedAt))",
                close: requestClose)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    FormGroup {
                        FormRow(label: "Name") {
                            TextField("Entry name", text: $draft.name)
                                .font(Typeface.body)
                                .multilineTextAlignment(.trailing)
                                .submitLabel(.done)
                        }
                        FormRow(label: "Section") { sectionPicker }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text(NumberFormatting.energy(nutrition[.energy].known)).font(Typeface.numLarge)
                        Text("kcal").font(Typeface.sans(14, relativeTo: .subheadline)).foregroundStyle(Palette.secondary)
                        Spacer(minLength: Spacing.s)
                        MacroLine(nutrition: nutrition)
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.top, Spacing.xs)
                    FormGroup(caption: "Foods · \(draft.foods.count)") {
                        ForEach(draft.foods) { food in
                            DraftItemRow(
                                item: draftItem(food), defaultWord: "saved",
                                setQuantity: { quantity in
                                    if let index = draft.foods.firstIndex(where: { $0.id == food.id }) {
                                        draft.foods[index].quantity = quantity
                                    }
                                },
                                showsDivider: false)
                            .padding(.leading, Spacing.l)
                            .padding(.trailing, Spacing.m)
                            // The last food can't be removed; delete the entry instead.
                            .swipeAction("Remove", isEnabled: draft.foods.count > 1) { remove(food) }
                        }
                    }
                    Label(note, systemImage: "info.circle")
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, Spacing.xs)
                    if draft.isOneOff {
                        Button("Save as a meal…") {
                            newMealName = draft.name
                            savingAsMeal = true
                        }
                        .buttonStyle(TextButtonStyle())
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            HStack(spacing: Spacing.s) {
                Button(action: delete) { Label("Delete", systemImage: "trash").labelStyle(CompactLabelStyle()) }
                    .buttonStyle(DestructiveButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isSaving)
                Button(hasChanges ? "Save" : "Done", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSaving)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.l)
        }
        .foregroundStyle(Palette.text)
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard changes to this entry?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive, action: close)
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Save as a meal", isPresented: $savingAsMeal) {
            TextField("Meal name", text: $newMealName)
            Button("Save") { Task { await saveAsMeal() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a saved meal from these foods and amounts. This entry stays as logged.")
        }
    }

    private var sectionPicker: some View {
        Menu {
            if model.hasSections {
                ForEach(model.activeSections) { section in
                    Button(section.name) { draft.assign(to: Destination(section: section)) }
                }
            }
            Button(Destination(section: nil).name) { draft.assign(to: Destination(section: nil)) }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(model.destinationName(for: draft))
                Image(systemName: "chevron.up.chevron.down").font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .font(Typeface.body)
            .foregroundStyle(Palette.secondary)
            .frame(minHeight: Metrics.tapTarget)
        }
        .accessibilityLabel("Section, \(model.destinationName(for: draft))")
    }

    private var note: String {
        if let id = draft.mealTemplateID, let meal = model.meal(id: id) {
            return "Changes apply to this entry only. Your saved “\(meal.name)” stays as it is. Nothing is saved until you tap Save."
        }
        return draft.isOneOff
            ? "One-off entry. It isn’t a saved meal unless you choose to save it."
            : "Changes apply to this entry only."
    }

    private func draftItem(_ food: LoggedFoodSnapshot) -> DraftItem {
        DraftItem(
            id: food.id, food: food.asFoodDefinition, quantity: food.quantity, unit: food.unit,
            templateQuantity: draft.mealTemplateID == nil ? nil : food.templateQuantity)
    }

    private func remove(_ food: LoggedFoodSnapshot) {
        withAnimation { draft.foods.removeAll { $0.id == food.id } }
    }

    /// Deletes right away; the Undo toast on the main screen brings it back.
    private func delete() {
        Task {
            await model.deleteEntry(original)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            close()
        }
    }

    private func requestClose() {
        if hasChanges { confirmingDiscard = true } else { close() }
    }

    private func save() {
        guard hasChanges else { return close() }
        isSaving = true
        Task {
            do {
                try await model.updateEntry(draft)
                close()
            } catch EntryValidationError.noFoods {
                model.errorMessage = "An entry needs at least one food with an amount above zero. To remove it, delete the entry."
            } catch {
                model.errorMessage = "Couldn’t save changes. \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func saveAsMeal() async {
        let foods = draft.foods.filter { $0.quantity > 0 }
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
