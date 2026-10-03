import InstalogCore
import SwiftUI

struct MealLibraryView: View {
    let model: DiaryModel
    @State private var removing: MealTemplate?

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(model.activeMeals) { meal in
                    NavigationLink {
                        MealEditorView(model: model, meal: meal, onDone: nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meal.name).font(Typeface.sans(15, .semibold))
                            Text(detail(meal)).font(Typeface.sans(12)).foregroundStyle(Palette.tertiary)
                        }
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Palette.raised)
                    .swipeActions {
                        Button("Remove", role: .destructive) { removing = meal }
                    }
                }
                NavigationLink {
                    MealEditorView(model: model, meal: nil, onDone: nil)
                } label: {
                    Label("New saved meal", systemImage: "plus").font(Typeface.sans(15, .semibold)).foregroundStyle(Palette.accent)
                }
                .listRowBackground(Palette.raised)
            } footer: {
                Text("Library order is creation order. Each section can show its own order.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sheet)
        .navigationTitle("Saved meals")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(removing?.name ?? "meal")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove meal", role: .destructive) {
                if let id = removing?.id {
                    Task {
                        do {
                            try await model.archiveMeal(id: id)
                        } catch {
                            model.errorMessage = "Couldn’t remove the meal. \(error.localizedDescription)"
                        }
                    }
                }
            }
        } message: {
            Text("It leaves every section and future choices. Entries you already logged keep their foods and nutrition.")
        }
        .foregroundStyle(Palette.text)
    }

    private func detail(_ meal: MealTemplate) -> String {
        let items = DraftItem.items(for: meal, foods: model.foods)
        let energy = (try? NutritionCalculator.summarize(items.map(\.calculatorItem)))?[.energy].known ?? 0
        let sections = model.sections(containing: meal.id).map(\.name)
        let count = meal.items.count == 1 ? "1 food" : "\(meal.items.count) foods"
        return ([count, "\(NumberFormatting.energy(energy)) kcal"] + sections).joined(separator: " · ")
    }
}

/// Create or edit a saved meal's name, foods, amounts and units. Saving changes future defaults only.
struct MealEditorView: View {
    let model: DiaryModel
    let meal: MealTemplate?
    let onDone: (() -> Void)?

    @State private var name = ""
    @State private var items: [DraftItem] = []
    @State private var pickingFood = false
    @State private var newFoods: [UUID: FoodDefinition] = [:]
    @State private var error: String?
    @State private var loaded = false
    @State private var isSaving = false
    @State private var confirmingDiscard = false
    /// A new meal keeps one id, so a stray second save updates instead of duplicating.
    @State private var newID = UUID()
    @Environment(\.dismiss) private var dismiss

    private var savedItems: [DraftItem] {
        guard let meal else { return [] }
        return DraftItem.items(for: meal, foods: model.foods).map {
            var item = $0
            item.templateQuantity = nil
            return item
        }
    }

    private var hasChanges: Bool {
        loaded && (name != (meal?.name ?? "") || items != savedItems)
    }

    var body: some View {
        let nutrition = (try? NutritionCalculator.summarize(items.map(\.calculatorItem))) ?? NutritionSummary()
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Typeface.sans(14))
                    .foregroundStyle(Palette.dangerText)
                    .listRowBackground(Palette.dangerSurface)
            }
            SwiftUI.Section {
                TextField("Meal name, e.g. Oats + yogurt", text: $name).font(Typeface.sans(17, .semibold))
                    .listRowBackground(Palette.raised)
            } header: {
                Caption("Name")
            }
            SwiftUI.Section {
                ForEach($items) { $item in
                    DraftItemRow(
                        item: item, defaultWord: "default", setQuantity: { item.quantity = $0 },
                        units: item.food.nutrition.supportedUnits, setUnit: { unit in
                            item.quantity = item.food.nutrition.convert(quantity: item.quantity, from: item.unit, to: unit)
                                ?? (unit == .gram || unit == .milliliter ? 100 : 1)
                            item.unit = unit
                        })
                    .listRowBackground(Palette.raised)
                }
                .onMove { items = items.moving(fromOffsets: $0, toOffset: $1) }
                .onDelete { items.remove(atOffsets: $0) }
                Button {
                    pickingFood = true
                } label: {
                    Label("Add food", systemImage: "plus").font(Typeface.sans(14, .semibold))
                }
                .foregroundStyle(Palette.accent)
                .listRowBackground(Palette.raised)
            } header: {
                HStack {
                    Caption("Foods")
                    Spacer()
                    Caption("\(NumberFormatting.energy(nutrition[.energy].known)) kcal")
                }
            } footer: {
                Text(meal == nil
                    ? "Default amounts can be adjusted each time you log, without changing the saved meal."
                    : "Changes apply to future logs only. Entries you already logged stay as they were.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sheet)
        .environment(\.editMode, .constant(.active))
        .navigationTitle(meal == nil ? "New saved meal" : "Edit meal")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .interactiveDismissDisabled(hasChanges)
        .toolbar {
            if onDone != nil || hasChanges {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: requestCancel) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).fontWeight(.semibold).disabled(isSaving)
            }
        }
        .confirmationDialog("Discard changes to this meal?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive, action: finish)
            Button("Keep editing", role: .cancel) {}
        }
        .sheet(isPresented: $pickingFood) {
            FoodPickerFlow(model: model, cancel: { pickingFood = false }) { food, quantity, unit in
                if model.foods[food.id] == nil { newFoods[food.id] = food }
                items.append(DraftItem(food: food, quantity: quantity, unit: unit))
                pickingFood = false
            }
            .presentationBackground(Palette.sheet)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = meal?.name ?? ""
            items = savedItems
        }
        .foregroundStyle(Palette.text)
    }

    private func requestCancel() {
        if hasChanges { confirmingDiscard = true } else { finish() }
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }

    private func save() {
        guard !isSaving else { return }
        var updated = meal ?? MealTemplate(id: newID, name: "", items: [], sortOrder: 0)
        updated.name = name
        updated.items = items.map { MealTemplateItem(id: $0.id, foodID: $0.food.id, defaultQuantity: $0.quantity, unit: $0.unit) }
        isSaving = true
        error = nil
        Task {
            do {
                try await model.saveMeal(updated, foods: Array(newFoods.values))
                finish()
            } catch {
                self.error = error.localizedDescription
                isSaving = false
            }
        }
    }
}

/// Search, review, then return a food with an amount.
struct FoodPickerFlow: View {
    let model: DiaryModel
    let cancel: () -> Void
    let onPick: (FoodDefinition, Double, MeasureUnit) -> Void
    @State private var path: [FoodPick] = []
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            FoodSearchView(
                model: model, query: $query, autoFocus: true,
                onQuickAdd: { recent in onPick(recent.food, recent.quantity, recent.unit) }
            ) { food, recent in
                path.append(FoodPick(food: food, recent: recent))
            }
            .padding(16)
            .background(Palette.sheet)
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
            .navigationDestination(for: FoodPick.self) { pick in
                FoodDetailView(food: pick.food, initial: pick.initial, actionTitle: "Add to meal", close: cancel) { quantity, unit in
                    onPick(pick.food, quantity, unit)
                }
            }
        }
        .errorAlert(model)
    }
}
