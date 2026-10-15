import InstalogCore
import SwiftUI
import UIKit

/// User-entered calorie and macro goals, plus optional nutrient targets and FDA references.
struct TargetsView: View {
    let model: DiaryModel
    @State private var editing: NutrientDefinition?
    /// Shown immediately while the preference saves, so the toggle doesn't flicker.
    @State private var pendingReferences: Bool?
    @State private var confirmingReset = false
    /// The last reset, offered for Undo for a few seconds.
    @State private var lastReset: TargetReset?

    private static let primary: [NutrientID] = [.energy, .protein, .carbohydrate, .fat]

    var body: some View {
        // Editing always applies from today, so show today's targets even while browsing a past day.
        let targets = model.effectiveTargets(on: model.today)
        let balance = model.macroBalance()
        List {
            if !model.isViewingToday {
                Label("Showing today’s targets. \(Format.dayHeading(model.viewedDate, today: model.today)) keeps the targets it had.", systemImage: "calendar")
                    .font(Typeface.sans(13))
                    .foregroundStyle(Palette.secondary)
                    .listRowBackground(Color.clear)
            }
            if !balance.isConsistent, let energy = balance.energy {
                mismatchBanner(macroKcal: balance.macroKcal, energy: energy)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            SwiftUI.Section {
                ForEach(Self.primary.compactMap(NutrientRegistry.definition(for:))) { definition in
                    NavigationLink { MacroTargetsEditor(model: model) } label: {
                        rowLabel(definition, target: targets[definition.id], showsChevron: false)
                    }
                    .listRowBackground(Palette.raised)
                    .accessibilityLabel(accessibilityText(definition, target: targets[definition.id]))
                }
            } header: {
                Caption("Calories & macros")
            } footer: {
                Text("Macros are checked against calories at 4 / 4 / 9 kcal per gram.")
            }
            SwiftUI.Section {
                Toggle("Show FDA reference values", isOn: Binding(
                    get: { pendingReferences ?? model.preferences.showReferenceValues },
                    set: { value in
                        pendingReferences = value
                        Task {
                            do {
                                try await model.setShowReferenceValues(value)
                            } catch {
                                model.errorMessage = "Couldn’t change that setting. \(error.localizedDescription)"
                            }
                            pendingReferences = nil
                        }
                    }))
                    .tint(Palette.accent)
                    .listRowBackground(Palette.raised)
                resetRow
            } footer: {
                Text(model.customMicronutrientTargets.isEmpty
                    ? "All nutrient targets with a Daily Value already use it. FDA Daily Values (2016, adults and children 4+) are standard nutrition-label references, the same for everyone. They aren’t personalized to you."
                    : "FDA Daily Values (2016, adults and children 4+) are standard nutrition-label references, the same for everyone. They aren’t personalized to you. Reset only changes nutrient targets that have a Daily Value; calories, macros and your other limits stay.")
            }
            ForEach(NutrientGroup.allCases.filter { $0 != .energyAndMacros }, id: \.self) { group in
                SwiftUI.Section {
                    ForEach(NutrientRegistry.definitions(in: group)) { definition in
                        row(definition, target: targets[definition.id])
                    }
                } header: {
                    Caption(group.title)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sheet)
        .navigationTitle("Targets")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { definition in
            TargetEditorSheet(model: model, definition: definition, close: { editing = nil })
        }
        .confirmationDialog(resetTitle, isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text(resetMessage)
        }
        .safeAreaInset(edge: .bottom) {
            if let lastReset {
                ToastView(
                    message: "Reset \(Format.count(lastReset.count, "target")) to FDA Daily Values",
                    undo: { undo(lastReset) }, dismiss: { self.lastReset = nil })
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: lastReset.nutrients) {
                        UIAccessibility.post(notification: .announcement, argument: "Reset to FDA Daily Values")
                        guard !UIAccessibility.isVoiceOverRunning else { return }
                        try? await Task.sleep(for: .seconds(6))
                        withAnimation { self.lastReset = nil }
                    }
            }
        }
        .foregroundStyle(Palette.text)
    }

    private var resetRow: some View {
        let count = model.customMicronutrientTargets.count
        let enabled = model.canResetMicronutrientTargets
        return Button { confirmingReset = true } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset all to FDA Daily Values").font(Typeface.bodyMedium)
                Spacer(minLength: Spacing.s)
                Text(count == 0 ? "none custom" : "\(count) custom")
                    .font(Typeface.numFootnote)
                    .foregroundStyle(enabled ? Palette.secondary : Palette.disabled)
            }
            .foregroundStyle(enabled ? Palette.accent : Palette.disabled)
            .frame(minHeight: Metrics.formRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .listRowBackground(Palette.raised)
    }

    private var resetTitle: String {
        let count = model.customMicronutrientTargets.count
        if count == 0 { return "Show FDA Daily Values again?" }
        return "Replace \(Format.count(count, "custom target")) with FDA Daily Values?"
    }

    private var resetMessage: String {
        let names = model.customMicronutrientTargets.compactMap { NutrientRegistry.definition(for: $0)?.name }
        var text = names.isEmpty ? "" : names.formatted(.list(type: .and)) + ". "
        if !model.preferences.showReferenceValues { text += "FDA reference values will show again. " }
        return text + "Past days keep their targets. Calories and macros aren’t changed."
    }

    private func reset() {
        Task {
            do {
                let result = try await model.resetMicronutrientTargets()
                withAnimation { lastReset = result.count > 0 ? result : nil }
            } catch {
                model.errorMessage = "Couldn’t reset your targets. \(error.localizedDescription)"
            }
        }
    }

    private func undo(_ reset: TargetReset) {
        withAnimation { lastReset = nil }
        Task {
            do {
                try await model.undoTargetReset(reset)
            } catch {
                model.errorMessage = "Couldn’t undo the reset. \(error.localizedDescription)"
            }
        }
    }

    /// Saved targets that contradict each other, e.g. from before targets were checked.
    private func mismatchBanner(macroKcal: Double, energy: Double) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.over)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s) {
                (Text("Targets don’t match. ").font(Typeface.calloutStrong)
                    + Text("Your macros add up to \(NumberFormatting.energy(macroKcal)) kcal, but calories are set to \(NumberFormatting.energy(energy)).")
                    .font(Typeface.subhead))
                    .foregroundStyle(Palette.text)
                NavigationLink { MacroTargetsEditor(model: model) } label: {
                    HStack(spacing: 3) {
                        Text("Review")
                        Image(systemName: "chevron.right").font(.system(.caption, weight: .semibold))
                    }
                    .font(Typeface.calloutStrong)
                    .foregroundStyle(Palette.over)
                    .frame(minHeight: Metrics.tapTarget)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.overSurface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
    }

    private func accessibilityText(_ definition: NutrientDefinition, target: EffectiveTarget?) -> String {
        "\(definition.name), \(target.map { "\($0.kind == .limit ? "limit" : "target") \(NumberFormatting.nutrient($0.amount, unit: $0.unit))" } ?? "not set")"
    }

    private func row(_ definition: NutrientDefinition, target: EffectiveTarget?) -> some View {
        Button { editing = definition } label: {
            rowLabel(definition, target: target, showsChevron: true)
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.raised)
        .accessibilityLabel(accessibilityText(definition, target: target))
    }

    private func rowLabel(_ definition: NutrientDefinition, target: EffectiveTarget?, showsChevron: Bool) -> some View {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(definition.name).font(Typeface.body)
                    if let target {
                        Text((target.kind == .limit ? "limit" : "target")
                            + (target.isReference ? " · FDA DV" : model.customMicronutrientTargets.contains(definition.id) ? " · custom" : ""))
                            .font(Typeface.numFootnote)
                            .foregroundStyle(Palette.tertiary)
                    }
                }
                Spacer()
                Text(target.map { NumberFormatting.nutrient($0.amount, unit: $0.unit) } ?? "Not set")
                    .font(Typeface.numCallout)
                    .foregroundStyle(target == nil ? Palette.tertiary : Palette.secondary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .frame(minHeight: Metrics.formRow)
            .contentShape(Rectangle())
    }
}

struct TargetEditor: View {
    let model: DiaryModel
    let definition: NutrientDefinition
    let close: () -> Void
    @State private var amount = ""
    @State private var kind: TargetKind = .target
    @State private var isSaving = false

    private var subtitle: String {
        if let reference = FDADailyValues.value(for: definition.id) {
            return "FDA Daily Value · \(NumberFormatting.nutrient(reference.amount, unit: reference.unit))"
        }
        return model.targets.contains { $0.nutrientID == definition.id }
            ? "Applies from today. Earlier days keep their targets."
            : "Your first target for this applies to every day."
    }

    var body: some View {
        let current = model.effectiveTargets(on: model.today)[definition.id]
        let reference = FDADailyValues.value(for: definition.id)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SheetHeader(title: definition.name, subtitle: subtitle, close: close)
                SegmentedControl(options: [("Target", TargetKind.target), ("Limit", TargetKind.limit)], selection: $kind)
                    .padding(.top, Spacing.xs)
                HStack(spacing: Spacing.s) {
                    Text(kind == .limit ? "Daily limit" : "Daily target")
                        .font(Typeface.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DecimalField(
                        text: $amount, accessibilityLabel: "\(definition.name) \(kind == .limit ? "limit" : "target") in \(definition.unit.rawValue)",
                        fontSize: 28)
                    Text(definition.unit.rawValue).font(Typeface.body).foregroundStyle(Palette.tertiary)
                }
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 64)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                Text(kind == .limit
                    ? "Limit: the bar turns orange once you go over."
                    : "Target: the bar fills as you get closer. Going over is shown, not flagged.")
                    .font(Typeface.footnote)
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, Spacing.xs)
                Button("Save") {
                    guard let value = QuantityInput.parse(amount) else {
                        model.errorMessage = "Enter a number of zero or more."
                        return
                    }
                    run { try await model.setTarget(definition.id, amount: value, kind: kind) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving)
                HStack(spacing: Spacing.s) {
                    if let reference, !(current?.isReference ?? false) {
                        Button("Use DV · \(NumberFormatting.nutrient(reference.amount, unit: reference.unit))") {
                            run { try await model.useReferenceValue(definition.id) }
                        }
                        .buttonStyle(SmallControlButtonStyle(color: Palette.accent))
                    }
                    if current != nil {
                        Button("Turn off") { run { try await model.disableTarget(definition.id) } }
                            .buttonStyle(SmallControlButtonStyle(color: Palette.text))
                    }
                }
                .disabled(isSaving)
            }
            .padding(Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Palette.text)
        .onAppear {
            if let current {
                amount = QuantityInput.text(current.amount)
                kind = current.kind == .limit ? .limit : .target
            }
        }
        .errorAlert(model)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await action()
                close()
            } catch {
                model.errorMessage = "Couldn’t save the target. \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}

/// Secondary actions that sit under a primary button: 44 pt, control background.
struct SmallControlButtonStyle: ButtonStyle {
    var color: Color = Palette.text
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.calloutStrong)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: Metrics.tapTarget)
            .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// The editor sized to its content: a fixed short sheet, or full height at large text sizes.
private struct TargetEditorSheet: View {
    let model: DiaryModel
    let definition: NutrientDefinition
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TargetEditor(model: model, definition: definition, close: close)
            .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(460), .large])
            .presentationBackground(Palette.sheet)
    }
}
