import InstalogCore
import SwiftUI

struct SettingsSheet: View {
    let model: DiaryModel
    let close: () -> Void
    // Shown immediately while a preference saves, so controls don't flicker or lose quick taps.
    @State private var pendingAutoAdvance: Bool?
    @State private var pendingMetrics: [NutrientID]?

    private var shownMetrics: [NutrientID] { pendingMetrics ?? model.preferences.summaryNutrients }

    static let summaryChoices: [NutrientID] = [
        .protein, .carbohydrate, .fat, .fiber, .sugars, .addedSugars, .saturatedFat, .sodium, .potassium,
        .calcium, .iron, .magnesium, .vitaminC, .vitaminD,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SheetHeader(title: "Settings", close: close)
                    group("Logging") { autoAdvance }
                    group("Daily summary", trailing: "\(shownMetrics.count) OF \(AppPreferences.maxSummaryNutrients)") { metrics }
                    group("Routine") {
                        VStack(spacing: 0) {
                            link("Order sections and assign meals") { SetupView(model: model, close: nil) }
                            Divider().overlay(Palette.border)
                            link("Saved meals", detail: "\(model.activeMeals.count)") { MealLibraryView(model: model) }
                            Divider().overlay(Palette.border)
                            link("Scheduled meals", detail: "\(model.activeSchedules.count)") { SchedulesView(model: model) }
                        }
                        .cardBackground(Palette.raised, radius: 18)
                    }
                    group("Goals") {
                        link("Calorie, macro and nutrient targets") { TargetsView(model: model) }
                            .cardBackground(Palette.raised, radius: 18)
                    }
                    group("Your data") {
                        link("Export or import") { DataView(model: model) }
                            .cardBackground(Palette.raised, radius: 18)
                    }
                    if model.activeMeals.isEmpty, model.catalog != nil {
                        Button("Load demo routine") {
                            Task {
                                do {
                                    try await model.loadDemoRoutine()
                                    close()
                                } catch {
                                    model.errorMessage = "Couldn’t load the demo routine. \(error.localizedDescription)"
                                }
                            }
                        }
                        .font(Typeface.sans(15, .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: 44)
                    }
                    Text("Food data: \(model.catalog?.sourceDescription ?? "unavailable"). Public domain. Everything stays on this device; there’s no account or cloud sync.")
                        .font(Typeface.sans(12))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 34)
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Palette.sheet)
        }
        .foregroundStyle(Palette.text)
    }

    private func group<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption(title)
                Spacer()
                if let trailing { Caption(trailing) }
            }
            .padding(.horizontal, 4)
            .padding(.top, 14)
            content()
        }
    }

    private var autoAdvance: some View {
        let unavailable = model.activeSections.count < 2
        return Toggle(isOn: Binding(
            get: { pendingAutoAdvance ?? model.preferences.autoProgression },
            set: { value in
                pendingAutoAdvance = value
                Task {
                    do {
                        try await model.setAutoProgression(value)
                    } catch {
                        model.errorMessage = "Couldn’t change that setting. \(error.localizedDescription)"
                    }
                    pendingAutoAdvance = nil
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-advance after logging").font(Typeface.sans(16, .semibold))
                Text(unavailable
                    ? "Needs at least two sections. You’re using a single daily log."
                    : "After you log from a section’s meal card, move on to the next section. Stops at the last one. Add food never moves you.")
                    .font(Typeface.sans(13))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .tint(Palette.accent)
        .disabled(unavailable)
        .padding(14)
        .cardBackground(Palette.raised, radius: 18)
    }

    private var metrics: some View {
        let selected = shownMetrics
        let full = selected.count >= AppPreferences.maxSummaryNutrients
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pick up to \(AppPreferences.maxSummaryNutrients) metrics to show under calories. At least one stays on. Hidden nutrients are still tracked.")
                .font(Typeface.sans(14))
                .foregroundStyle(Palette.secondary)
            FlowLayout(spacing: 8) {
                ForEach(Self.summaryChoices, id: \.self) { id in
                    let isOn = selected.contains(id)
                    Button {
                        var updated = selected
                        if isOn {
                            guard updated.count > 1 else {
                                model.errorMessage = "Keep at least one metric under calories."
                                return
                            }
                            updated.removeAll { $0 == id }
                        } else {
                            guard !full else { return }
                            updated.append(id)
                        }
                        pendingMetrics = updated
                        Task {
                            do {
                                try await model.setSummaryNutrients(updated)
                            } catch {
                                model.errorMessage = "Couldn’t change the summary. \(error.localizedDescription)"
                            }
                            if pendingMetrics == updated { pendingMetrics = nil }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Palette.nutrientColor(id)).frame(width: 8, height: 8)
                            Text(NutrientRegistry.definition(for: id)?.shortName ?? id.rawValue)
                            if isOn { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                        }
                        .font(Typeface.sans(14, .medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(isOn ? Palette.badge : .clear, in: Capsule())
                        .overlay(Capsule().stroke(isOn ? Palette.handle : Palette.outline))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOn && full)
                    .opacity(!isOn && full ? 0.45 : 1)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .padding(16)
        .cardBackground(Palette.raised, radius: 18)
    }

    private func link<Destination: View>(_ title: String, detail: String? = nil, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title).font(Typeface.sans(15, .medium))
                Spacer()
                if let detail { Text(detail).font(Typeface.mono(13)).foregroundStyle(Palette.tertiary) }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct ErrorAlert: ViewModifier {
    let model: DiaryModel

    func body(content: Content) -> some View {
        content.alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension View {
    func errorAlert(_ model: DiaryModel) -> some View { modifier(ErrorAlert(model: model)) }
}
