import InstalogCore
import SwiftUI

/// Create or edit a food from known nutrition information. Blank fields stay unknown; an entered 0 is known.
struct CustomFoodForm: View {
    let model: DiaryModel
    let editing: FoodDefinition?
    let onSave: (FoodDefinition) -> Void

    @State private var name: String
    @State private var brand = ""
    @State private var basisAmount = "100"
    @State private var dimension: MeasureDimension = .mass
    @State private var servingName = "serving"
    @State private var servingGrams = ""
    @State private var values: [NutrientID: String] = [:]
    @State private var showMore = false
    @State private var error: String?
    @State private var isSaving = false
    @State private var confirmingDiscard = false
    @State private var initialSnapshot: [String] = []
    /// A new food keeps one id, so a stray second save updates instead of duplicating.
    @State private var newID = UUID()
    @Environment(\.dismiss) private var dismiss

    private static let primary: [NutrientID] = [
        .energy, .protein, .carbohydrate, .fat, .fiber, .sugars, .saturatedFat, .sodium,
    ]

    init(model: DiaryModel, editing: FoodDefinition? = nil, initialName: String = "", onSave: @escaping (FoodDefinition) -> Void) {
        self.model = model
        self.editing = editing
        self.onSave = onSave
        guard let food = editing else {
            _name = State(initialValue: initialName)
            return
        }
        let basis = food.nutrition.basis
        _name = State(initialValue: food.name)
        _brand = State(initialValue: food.brand ?? "")
        _basisAmount = State(initialValue: QuantityInput.text(basis.amount))
        _dimension = State(initialValue: basis.dimension)
        _servingName = State(initialValue: basis.servingName ?? "serving")
        _servingGrams = State(initialValue: basis.servingGrams.map { QuantityInput.text($0) } ?? "")
        _values = State(initialValue: food.nutrition.nutrients.values.mapValues { QuantityInput.text($0) })
        _showMore = State(initialValue: food.nutrition.nutrients.nutrientIDs.contains { !Self.primary.contains($0) })
    }

    /// Everything the user can change, for detecting unsaved edits.
    private var snapshot: [String] {
        [name, brand, basisAmount, "\(dimension)", servingName, servingGrams]
            + values.filter { !$0.value.isEmpty }.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
    }

    private var hasChanges: Bool { !initialSnapshot.isEmpty && snapshot != initialSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: editing == nil ? "New food" : "Edit food",
                subtitle: editing == nil ? "Saved to Your foods" : "Entries you already logged keep their nutrition",
                close: requestCancel)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Typeface.callout)
                            .foregroundStyle(Palette.dangerText)
                            .padding(Spacing.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.dangerSurface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                    }
                    FormGroup(caption: "Food") {
                        textRow("Name", text: $name, placeholder: "Required")
                        textRow("Brand", text: $brand, placeholder: "Optional")
                    }
                    FormGroup(caption: "Nutrition basis", footnote: "Use the label’s serving, or a 100 g / 100 mL basis.") {
                        FormRow(label: "Values are per") {
                            Menu {
                                Picker("Values are per", selection: $dimension) {
                                    Text("Grams").tag(MeasureDimension.mass)
                                    Text("Milliliters").tag(MeasureDimension.volume)
                                    Text("Serving").tag(MeasureDimension.serving)
                                }
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Text(dimension == .mass ? "Grams" : dimension == .volume ? "Milliliters" : "Serving")
                                    Image(systemName: "chevron.up.chevron.down").font(.system(.caption, weight: .semibold))
                                        .foregroundStyle(Palette.tertiary)
                                }
                                .font(Typeface.body)
                                .foregroundStyle(Palette.secondary)
                                .frame(minHeight: Metrics.tapTarget)
                            }
                        }
                        NumberFormRow(
                            label: "Amount", text: $basisAmount,
                            unit: dimension == .mass ? "g" : dimension == .volume ? "mL" : servingName, placeholder: "required")
                        if dimension == .serving {
                            textRow("Serving name", text: $servingName, placeholder: "bar, scoop…")
                            NumberFormRow(label: "Serving weight", text: $servingGrams, unit: "g", placeholder: "optional")
                        }
                    }
                    FormGroup(
                        caption: "Nutrients",
                        footnote: "Leave a field blank if the label doesn’t list it. Blank means unknown; 0 means none."
                    ) {
                        ForEach(Self.primary.compactMap(NutrientRegistry.definition(for:))) { field($0) }
                        if showMore {
                            ForEach(NutrientRegistry.all.filter { !Self.primary.contains($0.id) }) { field($0) }
                        }
                    }
                    Button {
                        withAnimation { showMore.toggle() }
                    } label: {
                        Label(showMore ? "Fewer nutrients" : "More nutrients", systemImage: showMore ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(TextButtonStyle())
                    .padding(.top, -Spacing.m)
                }
                .padding(Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            Button(editing == nil ? "Save food" : "Save changes", action: save)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.l)
        }
        .background(Palette.sheet)
        .foregroundStyle(Palette.text)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard this food?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .onAppear { if initialSnapshot.isEmpty { initialSnapshot = snapshot } }
        .onChange(of: dimension) { old, new in
            // A label's serving is "1 bar", not "100 bar"; switch the default amount with the basis.
            if new == .serving, basisAmount == "100" { basisAmount = "1" }
            if old == .serving, new != .serving, basisAmount == "1" { basisAmount = "100" }
        }
    }

    private func requestCancel() {
        if hasChanges { confirmingDiscard = true } else { dismiss() }
    }

    private func field(_ definition: NutrientDefinition) -> some View {
        NumberFormRow(
            label: definition.name,
            text: Binding(get: { values[definition.id] ?? "" }, set: { values[definition.id] = $0 }),
            unit: definition.unit.rawValue,
            isAcceptable: { $0.wholeMatch(of: /[0-9]{0,7}([.,][0-9]{0,3})?/) != nil })
    }

    private func textRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        FormRow(label: label) {
            TextField(placeholder, text: text)
                .font(Typeface.body)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(label)
        }
    }

    private func number(_ text: String) -> Double? { QuantityInput.parse(text) }

    private func save() {
        var profile = NutrientProfile()
        for (id, text) in values {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let value = number(text), value.isFinite, value >= 0 else {
                error = "\(NutrientRegistry.definition(for: id)?.name ?? id.rawValue) must be a number of zero or more."
                return
            }
            profile[id] = value
        }
        guard let amount = number(basisAmount) else {
            error = "Enter the amount the nutrition values refer to."
            return
        }
        var servingWeight: Double?
        if dimension == .serving, !servingGrams.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let grams = number(servingGrams), grams > 0 else {
                error = "Serving weight must be a number above zero, or left blank."
                return
            }
            servingWeight = grams
        }
        guard !isSaving else { return }
        let basis = NutritionBasis(
            amount: amount, dimension: dimension,
            servingName: dimension == .serving ? servingName.trimmingCharacters(in: .whitespaces) : nil,
            servingGrams: servingWeight)
        var food = editing ?? FoodDefinition(id: newID, source: .custom, name: "", nutrition: FoodNutrition(basis: basis, nutrients: profile))
        food.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        food.brand = brand.trimmingCharacters(in: .whitespaces).isEmpty ? nil : brand.trimmingCharacters(in: .whitespaces)
        // Portions and density from the original food stay as they were.
        food.nutrition.basis = basis
        food.nutrition.nutrients = profile
        isSaving = true
        error = nil
        Task {
            do {
                try await model.saveCustomFood(food)
                onSave(food)
            } catch {
                self.error = error.localizedDescription
                isSaving = false
            }
        }
    }
}
