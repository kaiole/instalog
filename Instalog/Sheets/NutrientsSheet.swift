import InstalogCore
import SwiftUI

/// Every supported nutrient for the viewed day, with honest completeness and target comparisons.
struct NutrientsSheet: View {
    let model: DiaryModel
    let close: () -> Void
    let openSettings: () -> Void
    @State private var showUnreported = false

    var body: some View {
        let day = model.dayNutrition
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetHeader(
                        title: "Nutrients",
                        subtitle: "\(Format.dayHeading(model.viewedDate, today: model.today)) · \(day.foodCount) foods logged",
                        close: close)
                    if day.isEmpty {
                        Text("Nothing logged yet. Templates and drafts don’t count until you log them.")
                            .font(Typeface.sans(14))
                            .foregroundStyle(Palette.secondary)
                    }
                    legend
                    ForEach(NutrientGroup.allCases, id: \.self) { group in
                        let rows = NutrientRegistry.definitions(in: group).filter { definition in
                            showUnreported || group == .energyAndMacros
                                || day.reportedNutrients.contains(definition.id)
                                || model.effectiveTargets[definition.id] != nil
                        }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Caption(group.title).padding(.horizontal, 4).padding(.bottom, 6)
                                VStack(spacing: 0) {
                                    ForEach(rows) { definition in
                                        NutrientRow(
                                            definition: definition,
                                            comparison: TargetResolver.compare(day[definition.id], with: model.effectiveTargets[definition.id]))
                                    }
                                }
                                .padding(.horizontal, 14)
                                .cardBackground(Palette.raised, radius: 18)
                            }
                        }
                    }
                    Toggle("Show nutrients no food reports", isOn: $showUnreported)
                        .font(Typeface.sans(14))
                        .tint(Palette.accent)
                        .padding(.horizontal, 4)
                    Button("Choose summary metrics…", action: openSettings)
                        .font(Typeface.sans(14, .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: 44)
                    Text("Reference values are FDA Daily Values (2016) for adults and children 4+, shown for general context. They aren’t personal requirements. Food data: \(model.catalog?.sourceDescription ?? "USDA FoodData Central"), plus your custom foods.")
                        .font(Typeface.sans(12))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(16)
                .padding(.top, 4)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .foregroundStyle(Palette.text)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            IncompleteMark()
            Text("Incomplete: some logged foods don’t report this nutrient, so the total is only what’s known.")
        }
        .font(Typeface.sans(12))
        .foregroundStyle(Palette.secondary)
    }
}

private struct NutrientRow: View {
    let definition: NutrientDefinition
    let comparison: TargetComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(definition.name).font(Typeface.sans(15, .medium))
                if comparison.isQualified { IncompleteMark() }
                Spacer()
                Text(amountText)
                    .font(Typeface.mono(14, .medium))
                    .foregroundStyle(comparison.total.displayAmount == nil ? Palette.tertiary : Palette.text)
            }
            if let fraction = comparison.fraction {
                ProgressView(value: min(1, fraction))
                    .tint(comparison.target?.kind == .limit && fraction > 1 ? Palette.dangerText : Palette.nutrientColor(definition.id))
                    .accessibilityHidden(true)
            }
            if let detail = detailText {
                Text(detail).font(Typeface.sans(12)).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        Format.amountWithUnit(comparison.total, unit: definition.unit)
    }

    private var detailText: String? {
        var parts: [String] = []
        if let target = comparison.target {
            let kind = switch target.kind {
            case .limit: "Limit"
            case .target: "Target"
            case .reference: "Reference"
            }
            var text = "\(kind) \(NumberFormatting.nutrient(target.amount, unit: target.unit))"
            if case .referenceTable(let name, _) = target.source { text += " · \(name)" }
            if let percent = comparison.fraction.flatMap(NumberFormatting.percent) { text += " · \(percent)" }
            if !comparison.isComparable { text += " · not comparable with this data (\(target.form ?? "form") vs \(definition.form ?? "reported form"))" }
            parts.append(text)
        }
        if let note = Format.completenessNote(comparison.total), comparison.total.completeness == .partial {
            parts.append(note)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
