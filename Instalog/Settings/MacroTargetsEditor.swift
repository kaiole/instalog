import InstalogCore
import SwiftUI

/// Calories and macros edited together, in grams or as percent of calories. Nothing adjusts on
/// its own: a live line shows what the macros add up to at 4 / 4 / 9 kcal per gram, and a
/// contradiction (macros needing more than the calorie target) blocks Save and offers fixes.
struct MacroTargetsEditor: View {
    let model: DiaryModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: MacroTargetMode = .grams
    @State private var energyText = ""
    /// Grams in grams mode, percent of calories in percent mode. Empty turns the target off.
    @State private var macroTexts: [NutrientID: String] = [:]
    @State private var lastEdited: NutrientID?
    @State private var focused: NutrientID?
    @State private var isSaving = false
    @State private var loaded = false

    private static let macros = MacroBalance.macros

    var body: some View {
        let balance = self.balance
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Applies from today. Earlier days keep theirs.")
                    .font(Typeface.subhead)
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, Spacing.xs)
                SegmentedControl(
                    options: [("Grams", MacroTargetMode.grams), ("Percent", MacroTargetMode.percent)],
                    selection: Binding(get: { mode }, set: switchMode))
                VStack(spacing: 0) {
                    energyRow(balance)
                    ForEach(Self.macros, id: \.self) { macro in
                        Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Spacing.l)
                        macroRow(macro, balance: balance)
                    }
                }
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                Text("Leave a field empty to turn it off. Checked at 4 / 4 / 9 kcal per gram.")
                    .font(Typeface.footnote)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, Spacing.xs)
                if mode == .percent { percentTotal } else { status(balance) }
                if let blocked = blockedReason {
                    Text(blocked)
                        .font(Typeface.footnote)
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xs)
                }
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(blockedReason != nil || isSaving)
            }
            .padding(Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.sheet)
        .foregroundStyle(Palette.text)
        .navigationTitle("Calories & macros")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    // MARK: Values

    private func value(_ text: String) -> Double? {
        QuantityInput.parse(text).map { min($0, NutritionTarget.maximumAmount) }
    }

    private var energy: Double? { value(energyText) }

    private func percent(_ macro: NutrientID) -> Double? {
        mode == .percent ? value(macroTexts[macro] ?? "") : nil
    }

    /// The targets as grams, whichever way they're being entered.
    private var balance: MacroBalance {
        var balance = MacroBalance(energy: energy)
        for macro in Self.macros {
            let entered = value(macroTexts[macro] ?? "")
            switch mode {
            case .grams: balance[macro] = entered
            case .percent: balance[macro] = entered.flatMap { pct in energy.map { MacroBalance.grams(percent: pct, of: $0, macro: macro) } }
            }
        }
        return balance
    }

    private var percentSum: Double { Self.macros.compactMap(percent).reduce(0, +) }
    private var hasPercents: Bool { Self.macros.contains { percent($0) != nil } }

    /// Why Save is off, or nil when the targets can be saved.
    private var blockedReason: String? {
        switch mode {
        case .grams:
            return balance.isConsistent ? nil : "Fix the mismatch to save."
        case .percent:
            guard hasPercents else { return nil }
            if energy == nil { return "Set calories to use percentages." }
            return abs(percentSum - 100) < 0.5 ? nil : "Save turns on when the total is 100%."
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        mode = model.preferences.macroTargetMode
        let current = model.macroBalance()
        energyText = current.energy.map { QuantityInput.text($0) } ?? ""
        for macro in Self.macros {
            macroTexts[macro] = text(for: macro, grams: current[macro], energy: current.energy, mode: mode)
        }
    }

    private func text(for macro: NutrientID, grams: Double?, energy: Double?, mode: MacroTargetMode) -> String {
        guard let grams else { return "" }
        switch mode {
        case .grams: return QuantityInput.text(grams)
        case .percent:
            guard let energy, energy > 0 else { return "" }
            return QuantityInput.text(MacroBalance.percent(grams: grams, of: energy, macro: macro))
        }
    }

    /// Converts what's typed so switching never loses a value; percentages that don't total 100
    /// stay that way and are shown, never quietly rebalanced.
    private func switchMode(_ new: MacroTargetMode) {
        guard new != mode else { return }
        let current = balance
        mode = new
        for macro in Self.macros {
            macroTexts[macro] = text(for: macro, grams: current[macro], energy: current.energy, mode: new)
        }
        Task {
            do {
                try await model.setMacroTargetMode(new)
            } catch {
                model.errorMessage = "Couldn’t change that setting. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Rows

    private func energyRow(_ balance: MacroBalance) -> some View {
        let isOff = energy == nil
        let isOver = !balance.isConsistent
        let subline = isOff
            ? (mode == .percent ? "Needed for percent" : "Not tracked")
            : (mode == .percent ? "Percent of this" : "Daily target")
        return row(
            id: .energy, name: "Calories", color: nil, subline: subline, sublineIsError: isOver,
            text: $energyText, unit: "kcal", trailingNote: nil)
    }

    private func macroRow(_ macro: NutrientID, balance: MacroBalance) -> some View {
        let definition = NutrientRegistry.definition(for: macro)
        let grams = balance[macro]
        let kcal = grams.map { $0 * MacroBalance.kcalPerGram(macro) }
        var subline = "Not tracked"
        if let kcal {
            subline = "\(NumberFormatting.energy(kcal)) kcal"
            if mode == .grams, let energy, energy > 0 {
                subline += " · \(NumberFormatting.nutrient(MacroBalance.percent(grams: grams ?? 0, of: energy, macro: macro)))%"
            }
        }
        let fixTarget = balance.fixes(lastEdited: lastEdited).compactMap { fix -> NutrientID? in
            if case .setMacro(let id, _) = fix { return id }
            return nil
        }.first
        return row(
            id: macro, name: definition?.shortName ?? macro.rawValue, color: Palette.nutrientColor(macro),
            subline: subline, sublineIsError: mode == .grams && fixTarget == macro,
            text: Binding(get: { macroTexts[macro] ?? "" }, set: { macroTexts[macro] = $0; lastEdited = macro }),
            unit: mode == .percent ? "%" : "g",
            trailingNote: mode == .percent ? grams.map { "\(NumberFormatting.nutrient($0)) g" } : nil)
    }

    private func row(
        id: NutrientID, name: String, color: Color?, subline: String, sublineIsError: Bool, text: Binding<String>,
        unit: String, trailingNote: String?
    ) -> some View {
        let isFocused = focused == id
        let isOff = text.wrappedValue.isEmpty
        return HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let color {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    }
                    Text(name).font(Typeface.body)
                }
                Text(subline)
                    .font(Typeface.numFootnote)
                    .foregroundStyle(sublineIsError ? Palette.dangerText : Palette.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailingNote {
                Text(trailingNote).font(Typeface.numCallout).foregroundStyle(Palette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                DecimalField(
                    text: text, textColor: sublineIsError ? Palette.dangerText : Palette.text,
                    accessibilityLabel: "\(name) in \(unit == "%" ? "percent" : unit)", fontSize: 22,
                    onEditingChanged: { editing in
                        if editing { focused = id } else if focused == id { focused = nil }
                    })
                    .overlay(alignment: .trailing) {
                        if isOff && !isFocused {
                            Text("Off")
                                .font(Typeface.mono(22, .semibold, relativeTo: .title3))
                                .foregroundStyle(Palette.tertiary)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                Text(isOff && !isFocused ? "" : unit)
                    .font(Typeface.subhead)
                    .foregroundStyle(Palette.tertiary)
                    .frame(minWidth: 28, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 64)
        .background(isFocused ? Palette.accentSurface : .clear)
    }

    // MARK: Status

    @ViewBuilder
    private func status(_ balance: MacroBalance) -> some View {
        switch balance.status {
        case .matches:
            StatusLine(
                icon: "checkmark.circle.fill", iconColor: Palette.accent,
                title: "Your macros add up to \(NumberFormatting.energy(balance.macroKcal)) kcal",
                detail: "Matches your \(NumberFormatting.energy(balance.energy ?? 0)) kcal within rounding.")
        case .under(let kcal) where balance.isConsistent:
            // A macro is off, so the rest of the calories are simply unassigned.
            StatusLine(
                icon: "info.circle", iconColor: Palette.secondary,
                title: "\(NumberFormatting.energy(kcal)) kcal not assigned to a macro",
                detail: "Macros add up to \(NumberFormatting.energy(balance.macroKcal)) of \(NumberFormatting.energy(balance.energy ?? 0)) kcal.")
        case .over(let kcal), .under(let kcal):
            let isOver = balance.macroKcal > (balance.energy ?? 0)
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Macros add up to \(NumberFormatting.energy(balance.macroKcal)) kcal")
                            .font(Typeface.calloutStrong)
                        Text("That’s \(NumberFormatting.energy(kcal)) \(isOver ? "more" : "less") than your \(NumberFormatting.energy(balance.energy ?? 0)) kcal calorie target. Pick one to fix:")
                            .font(Typeface.subhead)
                    }
                }
                .foregroundStyle(Palette.dangerText)
                ForEach(Array(balance.fixes(lastEdited: lastEdited).enumerated()), id: \.offset) { _, fix in
                    Button(label(for: fix)) { apply(fix) }
                        .buttonStyle(SmallControlButtonStyle(color: Palette.accent))
                }
            }
            .padding(Spacing.l)
            .background(Palette.dangerSurface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .accessibilityElement(children: .contain)
        case .unchecked:
            if balance.hasMacros {
                StatusLine(
                    icon: "info.circle", iconColor: Palette.secondary,
                    title: "Your macros add up to \(NumberFormatting.energy(balance.macroKcal)) kcal",
                    detail: "Set calories to check them against a target.")
            }
        }
    }

    private var percentTotal: some View {
        let sum = percentSum
        let left = 100 - sum
        let summary = abs(left) < 0.5
            ? "100% ✓"
            : left > 0 ? "\(NumberFormatting.nutrient(sum))% · \(NumberFormatting.nutrient(left))% left"
            : "\(NumberFormatting.nutrient(sum))% · \(NumberFormatting.nutrient(-left))% over"
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Total").font(Typeface.body)
                Spacer()
                Text(summary)
                    .font(Typeface.numCallout)
                    .foregroundStyle(left < -0.5 ? Palette.dangerText : Palette.text)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Self.macros, id: \.self) { macro in
                        let share = (percent(macro) ?? 0) / max(100, sum)
                        Rectangle().fill(Palette.nutrientColor(macro)).frame(width: max(0, proxy.size.width * share - 2))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Palette.control)
            .clipShape(Capsule())
            .accessibilityHidden(true)
        }
        .padding(Spacing.l)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func label(for fix: MacroBalance.Fix) -> String {
        switch fix {
        case .setCalories(let kcal): "Set calories to \(NumberFormatting.energy(kcal))"
        case .setMacro(let macro, let grams):
            "\(grams < (balance[macro] ?? 0) ? "Lower" : "Raise") \((NutrientRegistry.definition(for: macro)?.shortName ?? macro.rawValue).lowercased()) to \(NumberFormatting.nutrient(grams)) g"
        }
    }

    private func apply(_ fix: MacroBalance.Fix) {
        switch fix {
        case .setCalories(let kcal): energyText = QuantityInput.text(kcal)
        case .setMacro(let macro, let grams): macroTexts[macro] = QuantityInput.text(grams)
        }
    }

    private func save() {
        guard blockedReason == nil, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await model.setMacroTargets(balance)
                dismiss()
            } catch {
                model.errorMessage = "Couldn’t save the targets. \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

/// An icon with a bold first line and a quieter second line.
private struct StatusLine: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: icon).foregroundStyle(iconColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typeface.calloutStrong)
                Text(detail).font(Typeface.subhead).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}
