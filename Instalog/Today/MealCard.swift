import InstalogCore
import SwiftUI

/// The selected saved meal as a draft. Quantity edits apply to this log only.
struct MealCard: View {
    let model: DiaryModel

    var body: some View {
        let nutrition = model.draftNutrition
        let items = model.draftItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedMeal?.name ?? "")
                        .font(Typeface.title3)
                        .accessibilityAddTraits(.isHeader)
                    Text("Preview · not counted yet")
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xxs)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                .strokeBorder(Palette.handle, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Spacing.xs) {
                    Text(NumberFormatting.energy(nutrition[.energy].known))
                        .font(Typeface.numLarge)
                    Text("kcal").font(Typeface.footnote).foregroundStyle(Palette.tertiary)
                }
                .padding(.trailing, Spacing.xs)
            }
            MacroLine(nutrition: nutrition).padding(.top, Spacing.m).padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    DraftItemRow(
                        item: item, defaultWord: "default",
                        setQuantity: { model.setDraftQuantity($0, for: item.id) })
                }
            }
            if model.isDraftAdjusted {
                HStack(spacing: 10) {
                    Text("Adjusted for this log only. Your saved meal won’t change.")
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.secondary)
                    Spacer(minLength: 0)
                    Button("Reset") { model.resetDraft() }
                        .buttonStyle(TextButtonStyle())
                }
                .padding(.vertical, Spacing.xs)
            } else {
                Spacer().frame(height: Spacing.xs)
            }
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.m)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.xs)
        .cardBackground()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 50, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                withAnimation(.snappy) { model.browseMeals(by: dx < 0 ? 1 : -1) }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Next meal") { model.browseMeals(by: 1) }
        .accessibilityAction(named: "Previous meal") { model.browseMeals(by: -1) }
    }
}

struct MacroLine: View {
    let nutrition: NutritionSummary

    var body: some View {
        FlowLayout(spacing: 14) {
            macro("P", .protein)
            macro("C", .carbohydrate)
            macro("F", .fat)
        }
        .font(Typeface.numFootnote)
        .foregroundStyle(Palette.secondary)
    }

    private func macro(_ letter: String, _ id: NutrientID) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.nutrientColor(id)).frame(width: 7, height: 7)
            Text("\(letter) \(Format.amountWithUnit(nutrition[id], unit: .gram))")
            if nutrition[id].completeness == .partial { IncompleteMark() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One food with − / amount / + controls. Edited amounts are highlighted with their default.
/// At accessibility text sizes the stepper moves under the name and spans the row.
struct DraftItemRow: View {
    let item: DraftItem
    let defaultWord: String
    let setQuantity: (Double) -> Void
    var units: [MeasureUnit] = []
    var setUnit: ((MeasureUnit) -> Void)?
    var showsDivider = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    description
                    stepper(fillsWidth: true)
                }
                .padding(.vertical, Spacing.s)
            } else {
                HStack(spacing: 10) {
                    description
                    Spacer(minLength: 0)
                    stepper(fillsWidth: false)
                }
            }
        }
        .frame(minHeight: 60)
        .overlay(alignment: .top) {
            if showsDivider { Rectangle().fill(Palette.divider).frame(height: 1) }
        }
    }

    private var description: some View {
        let energy = (try? item.food.nutrition.nutrients(quantity: item.quantity, unit: item.unit))?[.energy]
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(item.food.name)
                .font(Typeface.bodyMedium)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Group {
                if item.isAdjusted, let template = item.templateQuantity {
                    Text("\(defaultWord) \(NumberFormatting.quantity(template)) \(item.food.nutrition.label(for: item.unit, quantity: template))")
                        .foregroundStyle(Palette.accent)
                } else {
                    Text(Format.energy(energy)).foregroundStyle(Palette.tertiary)
                }
            }
            .font(Typeface.numFootnote)
        }
    }

    private func stepper(fillsWidth: Bool) -> some View {
        QuantityStepper(
            name: item.food.name, quantity: item.quantity, unit: item.unit, unitLabel: item.unitLabel,
            highlighted: item.isAdjusted, units: units, unitLabelFor: { item.food.nutrition.label(for: $0) },
            setQuantity: setQuantity, setUnit: setUnit, fillsWidth: fillsWidth)
    }
}

/// − amount + for one food. Typing applies live, −/+ step from what's typed, and the field
/// always shows the value that will be logged.
struct QuantityStepper: View {
    let name: String
    let quantity: Double
    let unit: MeasureUnit
    let unitLabel: String
    var highlighted = false
    var units: [MeasureUnit] = []
    var unitLabelFor: (MeasureUnit) -> String = { _ in "" }
    let setQuantity: (Double) -> Void
    var setUnit: ((MeasureUnit) -> Void)?
    var fillsWidth = false

    @State private var text = ""
    @State private var isEditing = false
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        HStack(spacing: 0) {
            Button { step(QuantityStep.decrease) } label: {
                Image(systemName: "minus").frame(width: height, height: height).contentShape(Rectangle())
            }
            .disabled(quantity <= 0)
            .accessibilityLabel("Less \(name)")
            DecimalField(
                text: $text, textColor: highlighted ? Palette.accent : Palette.text,
                accessibilityLabel: "\(name), amount in \(unitLabel)",
                onEditingChanged: editingChanged)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, alignment: .trailing)
            unitView
            Button { step(QuantityStep.increase) } label: {
                Image(systemName: "plus").frame(width: height, height: height).contentShape(Rectangle())
            }
            .disabled(quantity >= QuantityInput.maximum(for: unit))
            .accessibilityLabel("More \(name)")
        }
        .frame(minHeight: height)
        .font(.system(.subheadline, weight: .semibold))
        .foregroundStyle(Palette.secondary)
        .buttonStyle(StepperButtonStyle())
        .background(isEditing ? Palette.accentSurface : .clear, in: shape)
        .overlay(shape.stroke(isEditing ? Palette.accent : Palette.outline, lineWidth: isEditing ? 2 : 1))
        .onAppear { text = QuantityInput.text(quantity) }
        .onChange(of: text) { _, new in typed(new) }
        .onChange(of: quantity) { _, new in external(new) }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(QuantityStep.increase)
            case .decrement: step(QuantityStep.decrease)
            @unknown default: break
            }
        }
    }

    /// Applies each valid keystroke. Partial input such as "1." or "" waits for more typing.
    private func typed(_ new: String) {
        guard let value = QuantityInput.parse(new) else { return }
        let clamped = QuantityInput.clamp(value, unit: unit)
        if !QuantityInput.same(clamped, value) { text = QuantityInput.text(clamped) }
        if !QuantityInput.same(clamped, quantity) { setQuantity(clamped) }
    }

    /// Mirrors changes made elsewhere (−/+, Reset, unit change) even while the field is focused.
    private func external(_ new: Double) {
        if let shown = QuantityInput.parse(text), QuantityInput.same(shown, new) { return }
        text = QuantityInput.text(new)
    }

    private func step(_ change: (Double, MeasureUnit) -> Double) {
        let base = QuantityInput.parse(text).map { QuantityInput.clamp($0, unit: unit) } ?? quantity
        let next = QuantityInput.clamp(change(base, unit), unit: unit)
        if next == 0 || next == QuantityInput.maximum(for: unit) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        setQuantity(next)
        if QuantityInput.parse(text).map({ !QuantityInput.same($0, next) }) ?? true {
            text = QuantityInput.text(next)
        }
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        guard !editing else { return }
        // Leaving "" or "1." behind shows the value that's actually in use.
        if QuantityInput.parse(text).map({ !QuantityInput.same($0, quantity) }) ?? true {
            text = QuantityInput.text(quantity)
        }
    }

    @ViewBuilder
    private var unitView: some View {
        let label = Text(shortUnit(unitLabel))
            .font(Typeface.sans(13, .medium, relativeTo: .subheadline))
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .fixedSize()
        if let setUnit, units.count > 1 {
            Menu {
                ForEach(units, id: \.self) { option in
                    Button(unitLabelFor(option)) { setUnit(option) }
                }
            } label: {
                HStack(spacing: 2) {
                    label
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(.horizontal, Spacing.s)
                .frame(minWidth: 44, minHeight: height)
                .overlay(alignment: .leading) {
                    Rectangle().fill(isEditing ? Palette.accentBorder : Palette.outline).frame(width: 1)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Unit, \(unitLabel)")
        } else {
            label.padding(.trailing, Spacing.xs)
        }
    }

    private func shortUnit(_ label: String) -> String {
        let first = label.split(separator: ",").first.map(String.init) ?? label
        return first.count > 10 ? String(first.prefix(9)) + "…" : first
    }
}

/// −/+ buttons inside the stepper: secondary when enabled, dimmed when at a limit.
private struct StepperButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Palette.secondary : Palette.disabled)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
