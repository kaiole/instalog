import InstalogCore
import SwiftUI

/// Consumed calories and the user's chosen summary nutrients. Drafts appear only as a preview.
struct SummaryHeader: View {
    let model: DiaryModel
    let openDetails: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let day = model.dayNutrition
        let energy = day[.energy]
        let target = model.effectiveTargets[.energy]
        let preview = model.selectedMeal == nil ? 0 : model.draftNutrition[.energy].known
        let isOver = target.map { energy.known > $0.amount } ?? false

        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: Spacing.m) {
                        consumed(energy: energy, target: target)
                        Spacer(minLength: 0)
                        remaining(energy: energy, target: target, preview: preview, isOver: isOver, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        consumed(energy: energy, target: target)
                        remaining(energy: energy, target: target, preview: preview, isOver: isOver, alignment: .leading)
                    }
                }
                ProgressBar(
                    value: energy.known, preview: preview, target: target?.amount, color: Palette.accent,
                    overColor: Palette.over, overHatched: false, height: 6
                )
                .padding(.top, 10)
                metrics(day)
                    .padding(.top, Spacing.m)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText(day: day, energy: energy, target: target))
        .accessibilityHint("Shows all nutrients for the day")
    }

    private func consumed(energy: NutrientTotal, target: EffectiveTarget?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Caption("Consumed")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(NumberFormatting.energy(energy.known))
                    .font(Typeface.display)
                    .tracking(-1)
                if energy.completeness == .partial { IncompleteMark() }
                Text(target.map { "/ \(NumberFormatting.energy($0.amount)) kcal" } ?? "kcal")
                    .font(Typeface.sans(14, relativeTo: .subheadline))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    private func remaining(
        energy: NutrientTotal, target: EffectiveTarget?, preview: Double, isOver: Bool, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if let target {
                let difference = abs(target.amount - energy.known)
                Text("\(NumberFormatting.energy(difference)) \(isOver ? "over" : "left")")
                    .font(Typeface.numCallout)
                    .foregroundStyle(isOver ? Palette.over : Palette.text)
            }
            if preview > 0 {
                Text("preview +\(NumberFormatting.energy(preview))")
                    .font(Typeface.mono(11, relativeTo: .caption2))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    @ViewBuilder
    private func metrics(_ day: NutritionSummary) -> some View {
        let columns = model.preferences.summaryNutrients.compactMap { id in
            NutrientRegistry.definition(for: id).map { ($0, TargetResolver.compare(day[id], with: model.effectiveTargets[id])) }
        }
        // At accessibility sizes the columns become a list, so numbers never shrink or truncate.
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(columns, id: \.0.id) { MetricColumn(definition: $0.0, comparison: $0.1) }
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.m) {
                ForEach(columns, id: \.0.id) {
                    MetricColumn(definition: $0.0, comparison: $0.1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func accessibilityText(day: NutritionSummary, energy: NutrientTotal, target: EffectiveTarget?) -> String {
        var text = "Consumed \(NumberFormatting.energy(energy.known)) calories"
        if let target {
            text += " of \(NumberFormatting.energy(target.amount))"
            let difference = target.amount - energy.known
            text += difference < 0 ? ", \(NumberFormatting.energy(-difference)) over" : ", \(NumberFormatting.energy(difference)) left"
        }
        if energy.completeness == .partial { text += ", incomplete" }
        for id in model.preferences.summaryNutrients {
            guard let definition = NutrientRegistry.definition(for: id) else { continue }
            let comparison = TargetResolver.compare(day[id], with: model.effectiveTargets[id])
            text += ". " + MetricColumn.describe(definition: definition, comparison: comparison)
        }
        return text
    }
}

private struct MetricColumn: View {
    let definition: NutrientDefinition
    let comparison: TargetComparison

    var body: some View {
        let over = overAmount
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.nutrientColor(definition.id)).frame(width: 8, height: 8)
                Text(definition.shortName)
                    .font(Typeface.footnote)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                if let over {
                    Spacer(minLength: Spacing.xs)
                    Text("\(NumberFormatting.nutrient(over)) over")
                        .font(Typeface.mono(11, relativeTo: .caption2))
                        .foregroundStyle(isLimit ? Palette.over : Palette.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 0) {
                Text(Format.amount(comparison.total, unit: definition.unit))
                    .fontWeight(.semibold)
                    .foregroundStyle(comparison.total.displayAmount == nil ? Palette.tertiary : Palette.text)
                Text(targetText).foregroundStyle(Palette.tertiary)
                if comparison.isQualified { IncompleteMark().padding(.leading, 3) }
            }
            .font(Typeface.numCallout)
            .lineLimit(1)
            ProgressBar(
                value: comparison.total.known, preview: 0, target: comparable ? comparison.target?.amount : nil,
                color: Palette.nutrientColor(definition.id),
                overColor: isLimit ? Palette.over : Palette.nutrientColor(definition.id), overHatched: !isLimit, height: 3
            )
            .padding(.top, 3)
            .opacity(comparison.fraction == nil ? 0.5 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.describe(definition: definition, comparison: comparison))
    }

    private var comparable: Bool { comparison.target != nil && comparison.isComparable }
    private var isLimit: Bool { comparison.target?.kind == .limit }

    private var overAmount: Double? {
        guard comparable, let target = comparison.target, comparison.total.known > target.amount else { return nil }
        return comparison.total.known - target.amount
    }

    private var targetText: String {
        guard let target = comparison.target, comparison.isComparable else { return " \(definition.unit.rawValue)" }
        return " / \(NumberFormatting.nutrient(target.amount)) \(definition.unit.rawValue)"
    }

    static func describe(definition: NutrientDefinition, comparison: TargetComparison) -> String {
        var text = "\(definition.name) \(Format.amountWithUnit(comparison.total, unit: definition.unit))"
        if let target = comparison.target, comparison.isComparable {
            text += " of \(NumberFormatting.nutrient(target.amount))"
            if comparison.total.known > target.amount {
                text += ", \(NumberFormatting.nutrient(comparison.total.known - target.amount)) over"
                if target.kind == .limit { text += " the limit" }
            }
        }
        if let note = Format.completenessNote(comparison.total) { text += ". \(note)" }
        return text
    }
}

/// A capsule bar. Under target it fills toward the target; once over, it rescales so the
/// target becomes a tick and the overflow shows in `overColor`. A preview appears hatched.
struct ProgressBar: View {
    let value: Double
    let preview: Double
    let target: Double?
    let color: Color
    let overColor: Color
    let overHatched: Bool
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = max(target ?? 0, value + preview, 1)
            let targetX = target.map { width * min(1, $0 / scale) }
            let valueX = width * min(1, value / scale)
            let previewX = width * min(1, (value + preview) / scale)
            let underX = min(valueX, targetX ?? valueX)
            let isOver = target.map { value > $0 } ?? false
            let previewColor = (target.map { value + preview > $0 } ?? false) ? overColor : color
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.control)
                HatchedFill(color: previewColor)
                    .frame(width: max(0, previewX - valueX))
                    .offset(x: valueX)
                Rectangle().fill(color).frame(width: underX)
                if isOver, let targetX {
                    Group {
                        if overHatched { HatchedFill(color: overColor) } else { Rectangle().fill(overColor) }
                    }
                    .frame(width: max(0, valueX - targetX))
                    .offset(x: targetX)
                }
            }
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if let targetX, value + preview > (target ?? 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.text)
                        .frame(width: 2, height: height + 6)
                        .offset(x: targetX - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Diagonal stripes marking an uncounted preview or a macro over its target.
private struct HatchedFill: View {
    var color: Color = Palette.accent

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 2)
                x += 5
            }
        }
    }
}
