import InstalogCore
import SwiftUI

/// Add food: log a saved meal, foods from search, or a custom food into the section it was
/// opened from. Never advances sections. Cancelling writes nothing.
struct AddFoodSheet: View {
    let model: DiaryModel
    let destination: Destination
    let date: LogDate
    let close: () -> Void

    @State private var query = ""
    @State private var plate: [DraftItem] = []
    @State private var plateMealID: UUID?
    @State private var plateName = ""
    @State private var showingPlate = false
    @State private var saveAsMeal = false
    @State private var path: [FoodPick] = []
    @State private var confirmingDiscard = false
    @State private var pendingMeal: MealTemplate?
    @State private var confirmingBack = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Add food", subtitle: subtitle, close: requestClose)
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.l)
                if showingPlate {
                    plateView
                } else {
                    browseView
                }
            }
            .background(Palette.sheet)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FoodPick.self) { pick in
                FoodDetailView(food: pick.food, initial: pick.initial, actionTitle: "Add to \(destinationLabel)", close: requestClose) { quantity, unit in
                    plate.append(DraftItem(food: pick.food, quantity: quantity, unit: unit))
                    path.removeAll()
                    showingPlate = true
                }
            }
        }
        .foregroundStyle(Palette.text)
        .interactiveDismissDisabled(hasWork)
        .confirmationDialog(discardTitle, isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: close)
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Nothing has been logged yet.")
        }
        .confirmationDialog(
            "Replace \(foodCount(plate.count)) with “\(pendingMeal?.name ?? "")”?",
            isPresented: Binding(get: { pendingMeal != nil }, set: { if !$0 { pendingMeal = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { if let pendingMeal { load(pendingMeal) } }
            Button("Keep my foods", role: .cancel) {}
        }
        .confirmationDialog("Discard your changes to this meal?", isPresented: $confirmingBack, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive, action: leaveSavedMeal)
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The amounts go back to the saved meal’s defaults.")
        }
    }

    /// True when closing would throw away something the user did.
    private var hasWork: Bool {
        plateMealID == nil ? !plate.isEmpty : isSavedMealEdited
    }

    private var isSavedMealEdited: Bool {
        guard let id = plateMealID, let meal = model.meal(id: id) else { return false }
        let defaults = DraftItem.items(for: meal, foods: model.foods)
        return plate.map(\.id) != defaults.map(\.id) || plate.contains(where: \.isAdjusted)
            || zip(plate, defaults).contains { $0.unit != $1.unit }
    }

    private var discardTitle: String {
        plateMealID == nil ? "Discard \(foodCount(plate.count))?" : "Discard your changes to this meal?"
    }

    private func foodCount(_ count: Int) -> String { count == 1 ? "1 food" : "\(count) foods" }

    private var autoName: String {
        guard let first = plate.first else { return "Entry name" }
        return plate.count == 1 ? first.food.name : "\(first.food.name) + \(plate.count - 1) more"
    }

    private var destinationLabel: String {
        destination.name
    }

    private var subtitle: String {
        "Logs to \(destinationLabel) · \(date == model.today ? "Today" : Format.shortDay(date))"
    }

    private func requestClose() {
        if hasWork { confirmingDiscard = true } else { close() }
    }

    // MARK: Browse

    private var browseView: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            FoodSearchView(
                model: model, query: $query, autoFocus: plate.isEmpty, onPickMeal: pick,
                onQuickAdd: { recent in
                    if plateMealID != nil { leaveSavedMeal() }
                    plate.append(DraftItem(food: recent.food, quantity: recent.quantity, unit: recent.unit))
                }
            ) { food, recent in
                path.append(FoodPick(food: food, recent: recent))
            }
            if !plate.isEmpty {
                Button {
                    showingPlate = true
                } label: {
                    HStack {
                        Text("\(foodCount(plate.count)) ready")
                        Spacer()
                        Text("Review").fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.l)
    }

    private func pick(_ meal: MealTemplate) {
        // Foods picked from search would be lost; ask first.
        if plateMealID == nil, !plate.isEmpty { pendingMeal = meal } else { load(meal) }
    }

    private func load(_ meal: MealTemplate) {
        pendingMeal = nil
        plate = DraftItem.items(for: meal, foods: model.foods)
        plateMealID = meal.id
        plateName = meal.name
        saveAsMeal = false
        showingPlate = true
    }

    // MARK: Plate

    private var plateView: some View {
        let nutrition = (try? NutritionCalculator.summarize(plate.map(\.calculatorItem))) ?? NutritionSummary()
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if plateMealID == nil {
                    showingPlate = false
                } else if isSavedMealEdited {
                    confirmingBack = true
                } else {
                    leaveSavedMeal()
                }
            } label: {
                Label(plateMealID != nil ? "All saved meals" : "Search more foods", systemImage: "chevron.left")
            }
            .buttonStyle(TextButtonStyle(color: Palette.secondary))
            .padding(.leading, -Spacing.s)
            if plateMealID != nil {
                Text(plateName).font(Typeface.title3).padding(.horizontal, Spacing.xs)
            } else {
                FormGroup {
                    FormRow(label: "Name") {
                        TextField(autoName, text: $plateName)
                            .font(Typeface.body)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Entry name")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(NumberFormatting.energy(nutrition[.energy].known)).font(Typeface.numLarge)
                Text("kcal").font(Typeface.sans(14, relativeTo: .subheadline)).foregroundStyle(Palette.secondary)
                Spacer(minLength: Spacing.s)
                MacroLine(nutrition: nutrition)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.top, Spacing.m)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    FormGroup(caption: "Foods · \(plate.count)") {
                        ForEach($plate) { $item in
                            DraftItemRow(
                                item: item, defaultWord: "default", setQuantity: { item.quantity = $0 },
                                units: item.food.nutrition.supportedUnits, setUnit: { unit in
                                    item.quantity = item.food.nutrition.convert(quantity: item.quantity, from: item.unit, to: unit)
                                        ?? (unit == .gram || unit == .milliliter ? 100 : 1)
                                    item.unit = unit
                                },
                                showsDivider: false)
                            .padding(.leading, Spacing.l)
                            .padding(.trailing, Spacing.m)
                            .swipeAction("Remove") {
                                let id = item.id
                                withAnimation { plate.removeAll { $0.id == id } }
                                if plate.isEmpty { showingPlate = false }
                            }
                        }
                    }
                    if plateMealID == nil {
                        Button {
                            showingPlate = false
                        } label: {
                            Label("Add another food", systemImage: "plus")
                        }
                        .buttonStyle(TextButtonStyle())
                        FormGroup {
                            FormRow(label: "Also save as a meal", detail: "Off by default. One-offs stay one-offs.") {
                                Toggle("Also save as a meal", isOn: $saveAsMeal).labelsHidden().tint(Palette.accent)
                            }
                        }
                    }
                }
                .padding(.top, Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                Task { await logPlate() }
            } label: {
                HStack {
                    Text("Log to \(destinationLabel)")
                    Spacer()
                    Text(NumberFormatting.energy(nutrition[.energy].known))
                        .font(Typeface.mono(14, .semibold))
                        .foregroundStyle(Palette.onAccentDim)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isLogging || !plate.contains { $0.quantity > 0 })
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func leaveSavedMeal() {
        showingPlate = false
        plate = []
        plateMealID = nil
        plateName = ""
    }

    private func logPlate() async {
        guard !model.isLogging, !plate.isEmpty else { return }
        let name = plateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryName = name.isEmpty ? autoName : name
        do {
            try await model.logAdditional(
                name: entryName, items: plate, mealTemplateID: plateMealID, destination: destination, date: date,
                saveAsMealNamed: saveAsMeal && plateMealID == nil ? entryName : nil)
            close()
        } catch is LoggingBusyError {
            // A second tap while the first log is saving; the first one wins.
        } catch {
            model.errorMessage = "Nothing was logged. \(error.localizedDescription)"
        }
    }
}
