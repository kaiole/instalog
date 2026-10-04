import InstalogCore
import SwiftUI

/// A food chosen from search, with the amount to start from when it came from Recent.
struct FoodPick: Hashable {
    let food: FoodDefinition
    var recent: RecentFood?

    var initial: (quantity: Double, unit: MeasureUnit)? { recent.map { ($0.quantity, $0.unit) } }
}

/// Search saved meals, your foods and the bundled USDA catalog from one field, narrowed by scope
/// chips. Empty, it shows Recent and Your foods. A catalog failure is shown as such and never
/// hides your own foods or the custom-food path.
struct FoodSearchView: View {
    enum Scope: Hashable {
        case all, meals, yours, usda
    }

    let model: DiaryModel
    /// Owned by the caller so the text survives leaving and coming back to search.
    @Binding var query: String
    var autoFocus = false
    /// Set to offer saved meals as results (Add food). Nil hides the meals scope.
    var onPickMeal: ((MealTemplate) -> Void)?
    /// Set to show a one-tap + on Recent rows that adds the food at the amount used last time.
    var onQuickAdd: ((RecentFood) -> Void)?
    /// Opens the detail screen; `RecentFood` carries the amount to start from.
    let onPick: (FoodDefinition, RecentFood?) -> Void

    @State private var scope: Scope = .all
    @State private var outcome: FoodSearchOutcome?
    @State private var outcomeQuery = ""
    @State private var isSearching = false
    @State private var recent: [RecentFood] = []
    @State private var creatingCustom = false
    @State private var editingFood: FoodDefinition?
    @State private var deletingFood: FoodDefinition?
    @State private var loadingID: String?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            searchField
            scopeChips
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.s) {
                    if trimmedQuery.isEmpty { emptyQueryResults } else { queryResults }
                }
                .padding(.bottom, Spacing.l)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .task(id: "\(query)|\(scope)") {
            let text = query
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty, scope == .all || scope == .usda || scope == .yours else {
                outcome = nil
                isSearching = false
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isSearching = true
            let result = await model.searchFoods(text)
            guard !Task.isCancelled else { return }
            outcome = result
            outcomeQuery = text
            isSearching = false
        }
        .task { recent = await model.recentFoods() }
        .onAppear { if autoFocus, query.isEmpty { searchFocused = true } }
        .sheet(isPresented: $creatingCustom) {
            NavigationStack {
                CustomFoodForm(model: model, editing: editingFood, initialName: editingFood == nil ? query : "") { food in
                    creatingCustom = false
                    if editingFood == nil { onPick(food, nil) }
                    editingFood = nil
                }
            }
            .presentationBackground(Palette.sheet)
        }
        .confirmationDialog(
            "Delete “\(deletingFood?.name ?? "")”?",
            isPresented: Binding(get: { deletingFood != nil }, set: { if !$0 { deletingFood = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete food", role: .destructive) {
                guard let food = deletingFood else { return }
                Task {
                    do {
                        try await model.archiveCustomFood(id: food.id)
                        recent.removeAll { $0.food.id == food.id }
                    } catch {
                        model.errorMessage = "Couldn’t delete “\(food.name)”. \(error.localizedDescription)"
                    }
                }
            }
        } message: {
            Text("It won’t appear in search anymore. Entries you already logged keep their nutrition.")
        }
    }

    // MARK: Field and scopes

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).accessibilityHidden(true)
            TextField(onPickMeal == nil ? "Search foods" : "Search foods and saved meals", text: $query)
                .font(Typeface.sans(16, relativeTo: .body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if isSearching {
                ProgressView().accessibilityLabel("Searching")
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                }
                .foregroundStyle(Palette.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, query.isEmpty ? Spacing.m : 2)
        .frame(minHeight: 48)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(searchFocused ? Palette.accent : .clear, lineWidth: 1.5))
    }

    private var scopeChips: some View {
        let options: [(String, Scope)] = [("All", .all)] + (onPickMeal == nil ? [] : [("Saved meals", .meals)])
            + [("Your foods", .yours), ("USDA", .usda)]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(options, id: \.1) { label, value in
                    Button(label) { scope = value }
                        .buttonStyle(ChipButtonStyle(isSelected: scope == value))
                        .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private var emptyQueryResults: some View {
        switch scope {
        case .all:
            if !recent.isEmpty {
                group("Recent") { ForEach(recent) { recentRow($0) } }
            }
            yourFoodsGroup(model.customFoods)
        case .meals:
            mealsGroup(model.activeMeals)
        case .yours:
            yourFoodsGroup(model.customFoods)
        case .usda:
            hint("Type to search \(model.catalog?.sourceDescription ?? "the USDA database").")
        }
    }

    @ViewBuilder
    private var queryResults: some View {
        let meals = matchingMeals
        if scope == .meals {
            if meals.isEmpty { noMatches } else { mealsGroup(meals) }
        } else if let outcome, outcomeQuery == query {
            if let error = outcome.catalogError, scope != .yours {
                Label("USDA search isn’t available right now (\(error)). Your foods and custom entry still work.", systemImage: "exclamationmark.triangle")
                    .font(Typeface.subhead)
                    .foregroundStyle(Palette.dangerText)
                    .padding(.horizontal, Spacing.xs)
            }
            if scope == .all, !meals.isEmpty { mealsGroup(meals) }
            if scope != .usda, !outcome.personalFoods.isEmpty {
                group("Your foods") { ForEach(outcome.personalFoods) { customRow($0) } }
            }
            if scope != .yours, !outcome.catalogFoods.isEmpty {
                group(model.catalog?.sourceDescription ?? "USDA") { ForEach(outcome.catalogFoods) { catalogRow($0) } }
            }
            let nothing = outcome.personalFoods.isEmpty && (scope == .yours || outcome.catalogFoods.isEmpty)
                && (scope != .all || meals.isEmpty)
            if nothing, outcome.catalogError == nil || scope == .yours { noMatches }
            if scope != .usda { newFoodButton }
        }
    }

    private var matchingMeals: [MealTemplate] {
        guard onPickMeal != nil else { return [] }
        let words = trimmedQuery.lowercased().split(separator: " ")
        return model.activeMeals.filter { meal in words.allSatisfy { meal.name.lowercased().contains($0) } }
    }

    private var noMatches: some View {
        EmptyStateView(
            systemImage: "magnifyingglass", title: "No matches for “\(trimmedQuery)”",
            message: "Try fewer words, or create a custom food.")
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Typeface.subhead)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.top, Spacing.s)
    }

    private var newFoodButton: some View {
        Button {
            editingFood = nil
            creatingCustom = true
        } label: {
            Label("Create a custom food", systemImage: "plus")
        }
        .buttonStyle(TextButtonStyle())
    }

    @ViewBuilder
    private func yourFoodsGroup(_ foods: [FoodDefinition]) -> some View {
        HStack {
            Caption("Your foods")
            Spacer()
            Button {
                editingFood = nil
                creatingCustom = true
            } label: {
                Label("New food", systemImage: "plus")
            }
            .buttonStyle(TextButtonStyle())
        }
        .padding(.leading, Spacing.xs)
        if foods.isEmpty {
            hint("Foods you create appear here.").padding(.top, -Spacing.s)
        } else {
            rows { ForEach(foods) { customRow($0) } }
        }
    }

    @ViewBuilder
    private func mealsGroup(_ meals: [MealTemplate]) -> some View {
        if meals.isEmpty {
            hint("No saved meals yet. Save one from any logged entry, or in Settings.")
        } else {
            group("Saved meals") { ForEach(meals) { mealRow($0) } }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Caption(title).padding(.horizontal, Spacing.xs).padding(.top, Spacing.xs)
            rows(content: content)
        }
    }

    private func rows<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        FormGroup(content: content)
    }

    // MARK: Rows

    private func recentRow(_ item: RecentFood) -> some View {
        let energy = (try? item.food.nutrition.nutrients(quantity: item.quantity, unit: item.unit))?[.energy]
        let amount = "\(NumberFormatting.quantity(item.quantity)) \(item.food.nutrition.label(for: item.unit, quantity: item.quantity))"
        return HStack(spacing: Spacing.s) {
            Button { onPick(item.food, item) } label: {
                resultLabel(name: item.food.name, detail: "last \(amount) · \(Format.energy(energy))", energy: nil, loading: false)
            }
            .buttonStyle(.plain)
            if let onQuickAdd {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onQuickAdd(item)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                        .background(Palette.badge, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(amount) \(item.food.name)")
            }
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, 6)
    }

    private func mealRow(_ meal: MealTemplate) -> some View {
        let items = DraftItem.items(for: meal, foods: model.foods)
        let energy = (try? NutritionCalculator.summarize(items.map(\.calculatorItem)))?[.energy].known
        let sections = model.sections(containing: meal.id).map(\.name)
        return Button { onPickMeal?(meal) } label: {
            resultLabel(
                name: meal.name, detail: ([Format.count(meal.items.count, "food")] + sections).joined(separator: " · "),
                energy: energy, loading: false, tag: "MEAL")
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.m)
    }

    private func customRow(_ food: FoodDefinition) -> some View {
        Button { onPick(food, nil) } label: {
            resultLabel(
                name: food.name, detail: [food.brand, food.nutrition.basis.label].compactMap { $0 }.joined(separator: " · "),
                energy: food.nutrition.nutrients[.energy], loading: false)
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.m)
        .contextMenu {
            Button { editingFood = food; creatingCustom = true } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { deletingFood = food } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityAction(named: "Edit") { editingFood = food; creatingCustom = true }
        .accessibilityAction(named: "Delete") { deletingFood = food }
    }

    private func catalogRow(_ summary: CatalogFoodSummary) -> some View {
        Button {
            // One food at a time; extra taps while it loads are ignored.
            guard loadingID == nil else { return }
            Task {
                loadingID = summary.id
                defer { loadingID = nil }
                do {
                    onPick(try await model.food(forCatalogID: summary.id), nil)
                } catch {
                    model.errorMessage = "Couldn’t open that food. \(error.localizedDescription)"
                }
            }
        } label: {
            resultLabel(
                name: summary.name,
                detail: [summary.sourceLabel, summary.category].compactMap { $0 }.joined(separator: " · "),
                energy: summary.energyPer100Grams, loading: loadingID == summary.id, per100g: true,
                preparation: summary.preparation)
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.m)
    }

    private func resultLabel(
        name: String, detail: String, energy: Double?, loading: Bool, per100g: Bool = false, preparation: String? = nil,
        tag: String? = nil
    ) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(Typeface.bodyMedium).foregroundStyle(Palette.text)
                    if let tag {
                        Text(tag)
                            .font(Typeface.mono(10, relativeTo: .caption2))
                            .tracking(0.6)
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Palette.outline))
                    }
                }
                HStack(spacing: 6) {
                    if let preparation {
                        Text(preparation)
                            .font(Typeface.sans(11, .semibold, relativeTo: .caption2))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Palette.control, in: Capsule())
                    }
                    Text(detail).font(Typeface.numFootnote).foregroundStyle(Palette.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if loading {
                ProgressView()
            } else if let energy {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(NumberFormatting.energy(energy)).font(Typeface.numCallout).foregroundStyle(Palette.secondary)
                    Text(per100g ? "kcal/100 g" : "kcal").font(Typeface.mono(10, relativeTo: .caption2)).foregroundStyle(Palette.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

/// Review a food's nutrition and portions, choose an amount, then add it.
struct FoodDetailView: View {
    let food: FoodDefinition
    let actionTitle: String
    var close: (() -> Void)?
    let onAdd: (Double, MeasureUnit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var quantity: Double
    @State private var unit: MeasureUnit
    @State private var showAll = false
    @State private var added = false

    /// Starts at `initial` (e.g. the amount used last time) when given and still valid.
    init(
        food: FoodDefinition, initial: (quantity: Double, unit: MeasureUnit)? = nil, actionTitle: String,
        close: (() -> Void)? = nil, onAdd: @escaping (Double, MeasureUnit) -> Void
    ) {
        self.food = food
        self.actionTitle = actionTitle
        self.close = close
        self.onAdd = onAdd
        if let initial, food.nutrition.supportedUnits.contains(initial.unit), initial.quantity > 0 {
            _unit = State(initialValue: initial.unit)
            _quantity = State(initialValue: initial.quantity)
        } else {
            let initialUnit = Self.defaultUnit(for: food.nutrition)
            _unit = State(initialValue: initialUnit)
            _quantity = State(initialValue: initialUnit == .gram || initialUnit == .milliliter ? 100 : 1)
        }
    }

    var body: some View {
        let nutrients = (try? food.nutrition.nutrients(quantity: quantity, unit: unit)) ?? NutrientProfile()
        let grams = food.nutrition.grams(quantity: quantity, unit: unit)
        let energy = Format.energy(nutrients[.energy])
        VStack(spacing: 0) {
            SheetHeader(title: food.name, subtitle: identity, back: { dismiss() }, close: close ?? { dismiss() })
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: Spacing.m) {
                            Text("Amount").font(Typeface.body).frame(maxWidth: .infinity, alignment: .leading)
                            QuantityStepper(
                                name: food.name, quantity: quantity, unit: unit,
                                unitLabel: food.nutrition.label(for: unit, quantity: quantity),
                                units: food.nutrition.supportedUnits, unitLabelFor: { unitDescription($0) },
                                setQuantity: { quantity = $0 }, setUnit: { newUnit in
                                    quantity = food.nutrition.convert(quantity: quantity, from: unit, to: newUnit)
                                        ?? (newUnit == .gram || newUnit == .milliliter ? 100 : 1)
                                    unit = newUnit
                                })
                        }
                        if let grams, unit != .gram {
                            Text("= \(NumberFormatting.quantity(grams)) g")
                                .font(Typeface.numFootnote)
                                .foregroundStyle(Palette.tertiary)
                                .padding(.trailing, Spacing.xs)
                        }
                    }
                    .padding(.leading, Spacing.l)
                    .padding(.trailing, Spacing.m)
                    .padding(.vertical, Spacing.m)
                    .cardBackground()
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            energyLabel(nutrients)
                            Spacer(minLength: Spacing.s)
                            macroLine(nutrients)
                        }
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            energyLabel(nutrients)
                            macroLine(nutrients)
                        }
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.top, Spacing.xs)
                    FormGroup {
                        ForEach(rows, id: \.id) { definition in
                            HStack {
                                Text(definition.name).font(Typeface.body)
                                Spacer(minLength: Spacing.s)
                                if let value = nutrients[definition.id] {
                                    Text(NumberFormatting.nutrient(value, unit: definition.unit)).font(Typeface.numCallout)
                                } else {
                                    Text(Format.unknown).font(Typeface.numCallout).foregroundStyle(Palette.tertiary)
                                }
                            }
                            .padding(.horizontal, Spacing.l)
                            .frame(minHeight: Metrics.tapTarget)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Label(
                            showAll ? "Show fewer nutrients" : "Show all \(food.nutrition.nutrients.nutrientIDs.count) nutrients",
                            systemImage: showAll ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(TextButtonStyle())
                    Text("Shown for \(NumberFormatting.quantity(quantity)) \(Format.unitName(food.nutrition.label(for: unit, quantity: quantity)))\(unit == .gram ? "" : grams.map { " (\(NumberFormatting.quantity($0)) g)" } ?? ""). The source lists nutrition \(food.nutrition.basis.label). “\(Format.unknown)” means it isn’t reported — not zero.")
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, Spacing.xs)
                }
                .padding(Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                guard !added else { return }
                added = true
                onAdd(quantity, unit)
            } label: {
                HStack {
                    Text(actionTitle)
                    Spacer(minLength: Spacing.s)
                    Text(energy).font(Typeface.mono(15, .semibold, relativeTo: .headline)).foregroundStyle(Palette.onAccentDim)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(quantity <= 0 || added)
            .accessibilityLabel("\(actionTitle), \(energy)")
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.l)
        }
        .background(Palette.sheet)
        .foregroundStyle(Palette.text)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func energyLabel(_ nutrients: NutrientProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(nutrients[.energy].map(NumberFormatting.energy) ?? Format.unknown).font(Typeface.display)
            Text("kcal").font(Typeface.sans(14, relativeTo: .subheadline)).foregroundStyle(Palette.secondary)
        }
    }

    private func macroLine(_ nutrients: NutrientProfile) -> some View {
        let item = NutritionCalculator.Item(nutrition: food.nutrition, quantity: quantity, unit: unit)
        return MacroLine(nutrition: (try? NutritionCalculator.summarize([item])) ?? NutritionSummary())
    }

    /// A recognizable single serving when the source has one, otherwise the basis unit.
    private static func defaultUnit(for nutrition: FoodNutrition) -> MeasureUnit {
        if nutrition.basis.dimension == .serving { return .serving }
        for keyword in ["medium", "serving", "large", "slice", "piece"] {
            if let portion = nutrition.portions.first(where: { $0.name.lowercased().contains(keyword) }) {
                return .portion(id: portion.id)
            }
        }
        return nutrition.basis.dimension == .volume ? .milliliter : .gram
    }

    private var identity: String {
        [food.sourceLabel, food.category, food.preparation, food.brand].compactMap { $0 }.joined(separator: " · ")
    }

    private var rows: [NutrientDefinition] {
        let summaryIDs: [NutrientID] = [
            .protein, .carbohydrate, .fat, .fiber, .sugars, .saturatedFat, .sodium, .cholesterol,
        ]
        if !showAll { return summaryIDs.compactMap(NutrientRegistry.definition(for:)) }
        return NutrientRegistry.all.filter { $0.id != .energy && food.nutrition.nutrients[$0.id] != nil }
    }

    private func unitDescription(_ unit: MeasureUnit) -> String {
        let label = food.nutrition.label(for: unit)
        if case .portion(let id) = unit, let grams = food.nutrition.portion(id: id)?.grams {
            return "\(label) (\(NumberFormatting.quantity(grams)) g)"
        }
        return label
    }
}
