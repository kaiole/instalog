import InstalogCore
import SwiftUI
import UIKit

/// What the summary previews on top of saved totals: an unsaved inline edit of a logged entry
/// (which can lower totals), or else the selected meal's draft. Only one at a time.
struct SummaryPreview {
    /// Day totals as they'd be after saving the inline edit; nil when not editing.
    let editedDay: NutritionSummary?
    let mealEnergy: Double

    init(model: DiaryModel) {
        editedDay = model.entryEditDayNutrition
        // An open entry takes over the preview, even before it has changes.
        mealEnergy = model.entryEdit == nil && model.selectedMeal != nil ? model.draftNutrition[.energy].known : 0
    }

    var isEdit: Bool { editedDay != nil }

    func delta(_ id: NutrientID, day: NutritionSummary) -> Double {
        if let editedDay { return editedDay[id].known - day[id].known }
        return id == .energy ? mealEnergy : 0
    }

    static func signed(_ value: Double, unit: NutrientUnit) -> String {
        let magnitude = unit == .kilocalorie ? NumberFormatting.energy(abs(value)) : NumberFormatting.nutrient(abs(value))
        return (value < 0 ? "−" : "+") + magnitude
    }
}

/// Consumed (or, on a future day, planned) calories and the user's chosen summary nutrients.
/// Drafts and unsaved edits appear only as a preview.
struct SummaryHeader: View {
    let model: DiaryModel
    let openDetails: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let day = model.dayNutrition
        let energy = day[.energy]
        let target = model.effectiveTargets[.energy]
        let summary = SummaryPreview(model: model)
        let preview = summary.delta(.energy, day: day)
        let isOver = target.map { energy.known > $0.amount } ?? false
        let scheduled = model.scheduledNutrition

        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: Spacing.m) {
                        consumed(energy: energy, target: target)
                        Spacer(minLength: 0)
                        remaining(
                            energy: energy, target: target, summary: summary, preview: preview,
                            scheduled: scheduled[.energy].known, isOver: isOver, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        consumed(energy: energy, target: target)
                        remaining(
                            energy: energy, target: target, summary: summary, preview: preview,
                            scheduled: scheduled[.energy].known, isOver: isOver, alignment: .leading)
                    }
                }
                ProgressBar(
                    value: energy.known, preview: preview, target: target?.amount, color: Palette.accent,
                    overColor: Palette.over, overHatched: false, height: 6, reserved: scheduled[.energy].known
                )
                .padding(.top, 10)
                metrics(day, summary: summary, scheduled: scheduled)
                    .padding(.top, Spacing.m)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText(
            day: day, energy: energy, target: target, summary: summary, scheduled: scheduled[.energy].known))
        .accessibilityHint("Shows all nutrients for the day")
    }

    private func consumed(energy: NutrientTotal, target: EffectiveTarget?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Caption(model.isViewingFuture ? "Planned" : "Consumed")
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
        energy: NutrientTotal, target: EffectiveTarget?, summary: SummaryPreview, preview: Double, scheduled: Double,
        isOver: Bool, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if let target {
                let difference = abs(target.amount - energy.known)
                Text("\(NumberFormatting.energy(difference)) \(isOver ? "over" : "left")")
                    .font(Typeface.numCallout)
                    .foregroundStyle(isOver ? Palette.over : Palette.text)
            }
            if let target, scheduled > 0 {
                let after = target.amount - energy.known - scheduled
                Label(SummaryHeader.afterScheduledLine(after), systemImage: "clock")
                    .labelStyle(CompactLabelStyle())
                    .font(Typeface.mono(11, relativeTo: .caption2))
                    .foregroundStyle(after < 0 ? Palette.over : Palette.secondary)
            }
            // The meal card's own preview isn't repeated here; its Log button already shows it.
            if summary.isEdit {
                Text(SummaryHeader.editLine(delta: preview, energy: energy.known, target: target))
                    .font(Typeface.mono(11, relativeTo: .caption2))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    /// "780 after scheduled", or "350 over after scheduled".
    static func afterScheduledLine(_ after: Double, short: Bool = false) -> String {
        let word = short ? "after sched." : "after scheduled"
        return after < 0 ? "\(NumberFormatting.energy(-after)) over \(word)" : "\(NumberFormatting.energy(after)) \(word)"
    }

    /// "edit −120 · 476 left": the change and where the day would land once saved.
    static func editLine(delta: Double, energy: Double, target: EffectiveTarget?) -> String {
        var text = "edit \(SummaryPreview.signed(delta, unit: .kilocalorie))"
        if let target {
            let after = target.amount - (energy + delta)
            text += " · \(NumberFormatting.energy(abs(after))) \(after < 0 ? "over" : "left")"
        }
        return text
    }

    @ViewBuilder
    private func metrics(_ day: NutritionSummary, summary: SummaryPreview, scheduled: NutritionSummary) -> some View {
        let columns = model.preferences.summaryNutrients.compactMap { id in
            NutrientRegistry.definition(for: id).map {
                ($0, TargetResolver.compare(day[id], with: model.effectiveTargets[id]), summary.isEdit ? summary.delta(id, day: day) : 0)
            }
        }
        let reserved = { (id: NutrientID) in scheduled[id].known }
        // At accessibility sizes the columns become a list, so numbers never shrink or truncate.
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(columns, id: \.0.id) {
                    MetricColumn(definition: $0.0, comparison: $0.1, delta: $0.2, reserved: reserved($0.0.id))
                }
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.m) {
                ForEach(columns, id: \.0.id) {
                    MetricColumn(definition: $0.0, comparison: $0.1, delta: $0.2, reserved: reserved($0.0.id))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func accessibilityText(
        day: NutritionSummary, energy: NutrientTotal, target: EffectiveTarget?, summary: SummaryPreview, scheduled: Double
    ) -> String {
        var text = "\(model.isViewingFuture ? "Planned" : "Consumed") \(NumberFormatting.energy(energy.known)) calories"
        if let target {
            text += " of \(NumberFormatting.energy(target.amount))"
            let difference = target.amount - energy.known
            text += difference < 0 ? ", \(NumberFormatting.energy(-difference)) over" : ", \(NumberFormatting.energy(difference)) left"
        }
        if energy.completeness == .partial { text += ", incomplete" }
        if let target, scheduled > 0 {
            let after = target.amount - energy.known - scheduled
            text += ". \(NumberFormatting.energy(abs(after))) \(after < 0 ? "over" : "left") after scheduled meals"
        }
        if summary.isEdit {
            let delta = summary.delta(.energy, day: day)
            text += ". Unsaved edit, \(delta < 0 ? "minus" : "plus") \(NumberFormatting.energy(abs(delta))) calories"
        }
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
    /// Unsaved inline-edit change, shown beside the label and in the bar.
    var delta: Double = 0
    /// Still to come from scheduled meals, shown hollow in the bar.
    var reserved: Double = 0

    private var hasDelta: Bool { abs(delta) >= 0.5 }

    var body: some View {
        let over = overAmount
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.nutrientColor(definition.id)).frame(width: 8, height: 8)
                Text(definition.shortName)
                    .font(Typeface.footnote)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                if hasDelta {
                    Spacer(minLength: Spacing.xs)
                    Text("\(SummaryPreview.signed(delta, unit: definition.unit)) \(definition.unit.rawValue)")
                        .font(Typeface.mono(11, relativeTo: .caption2))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                } else if let over {
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
                value: comparison.total.known, preview: hasDelta ? delta : 0, target: comparable ? comparison.target?.amount : nil,
                color: Palette.nutrientColor(definition.id),
                overColor: isLimit ? Palette.over : Palette.nutrientColor(definition.id), overHatched: !isLimit, height: 3,
                reserved: comparable ? reserved : 0
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
/// target becomes a tick and the overflow shows in `overColor`. A positive preview appears
/// hatched; a negative one (an edit that removes food) leaves a ghost where the amount was.
struct ProgressBar: View {
    let value: Double
    let preview: Double
    let target: Double?
    let color: Color
    let overColor: Color
    let overHatched: Bool
    let height: CGFloat
    /// Scheduled but not eaten yet: a hollow segment after what's eaten, before any preview.
    var reserved: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let added = max(0, preview)
            let held = max(0, reserved)
            // With a negative preview the solid fill shows the lower amount and the rest is a ghost.
            let shown = max(0, value + min(0, preview))
            let scale = max(target ?? 0, value + added + held, 1)
            let targetX = target.map { width * min(1, $0 / scale) }
            let valueX = width * min(1, shown / scale)
            let ghostX = width * min(1, value / scale)
            let reservedX = width * min(1, (value + held) / scale)
            let previewX = width * min(1, (value + held + added) / scale)
            let underX = min(valueX, targetX ?? valueX)
            let isOver = target.map { shown > $0 } ?? false
            let previewColor = (target.map { value + held + added > $0 } ?? false) ? overColor : color
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.control)
                Rectangle()
                    .fill(Palette.text.opacity(0.06))
                    .overlay(Rectangle().strokeBorder(Palette.text.opacity(0.42), lineWidth: 1))
                    .frame(width: max(0, reservedX - ghostX))
                    .offset(x: ghostX)
                HatchedFill(color: previewColor)
                    .frame(width: max(0, previewX - reservedX))
                    .offset(x: reservedX)
                Rectangle()
                    .fill(color.opacity(0.28))
                    .overlay(Rectangle().strokeBorder(color.opacity(0.6), lineWidth: 1))
                    .frame(width: max(0, ghostX - valueX))
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
                if let targetX, value + held + added > (target ?? 0) {
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

/// One line that stays while the on-screen keyboard is up, so day totals and any edit's effect
/// stay in view. Tapping it puts the keyboard away.
struct CompactSummary: View {
    let model: DiaryModel

    var body: some View {
        let day = model.dayNutrition
        let energy = day[.energy].known
        let target = model.effectiveTargets[.energy]
        let summary = SummaryPreview(model: model)
        let delta = summary.delta(.energy, day: day)
        let scheduled = model.scheduledNutrition[.energy].known
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(NumberFormatting.energy(energy))
                        .font(Typeface.mono(17, .semibold, relativeTo: .headline))
                    + Text(target.map { " / \(NumberFormatting.energy($0.amount)) kcal" } ?? " kcal")
                        .font(Typeface.sans(13, relativeTo: .footnote))
                        .foregroundStyle(Palette.secondary)
                    if let target {
                        let left = target.amount - energy
                        Text("\(NumberFormatting.energy(abs(left))) \(left < 0 ? "over" : "left")")
                            .font(Typeface.sans(13, relativeTo: .footnote))
                            .foregroundStyle(left < 0 ? Palette.over : Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    if summary.isEdit {
                        Text(SummaryHeader.editLine(delta: delta, energy: energy, target: target).replacingOccurrences(of: "edit ", with: ""))
                            .font(Typeface.mono(11, relativeTo: .caption2))
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, 3)
                            .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    } else if let target, scheduled > 0 {
                        // One chip at a time: an entry edit wins over the scheduled figure.
                        let after = target.amount - energy - scheduled
                        Label(SummaryHeader.afterScheduledLine(after, short: true), systemImage: "clock")
                            .labelStyle(CompactLabelStyle())
                            .font(Typeface.mono(11, relativeTo: .caption2))
                            .foregroundStyle(after < 0 ? Palette.over : Palette.secondary)
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, 3)
                            .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    }
                }
                .lineLimit(1)
                ProgressBar(
                    value: energy, preview: delta, target: target?.amount, color: Palette.accent,
                    overColor: Palette.over, overHatched: false, height: 3, reserved: scheduled)
            }
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText(energy: energy, target: target, delta: summary.isEdit ? delta : nil))
        .accessibilityHint("Hides the keyboard")
    }

    private func accessibilityText(energy: Double, target: EffectiveTarget?, delta: Double?) -> String {
        var text = "\(NumberFormatting.energy(energy)) calories"
        if let target {
            let left = target.amount - energy
            text += " of \(NumberFormatting.energy(target.amount)), \(NumberFormatting.energy(abs(left))) \(left < 0 ? "over" : "left")"
        }
        if let delta { text += ". Unsaved edit, \(delta < 0 ? "minus" : "plus") \(NumberFormatting.energy(abs(delta)))" }
        return text
    }
}
