import InstalogCore
import SwiftUI

/// The current section: its logged entries first, then the meal chooser and the selected meal.
struct SectionCard: View {
    let model: DiaryModel
    @Binding var sheet: ActiveSheet?
    /// False when the whole screen scrolls (accessibility text sizes), so the card doesn't nest a scroll view.
    var scrollsInternally = true
    @State private var loggedExpanded = true
    @State private var revealedEntryID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if scrollsInternally {
                ScrollView { content }
                    .scrollDismissesKeyboard(.interactively)
            } else {
                content
            }
        }
        .padding(Spacing.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).stroke(Palette.border))
        .onChange(of: model.currentDestination.id) { revealedEntryID = nil }
    }

    private var content: some View {
                VStack(spacing: Spacing.m) {
                    LoggedEntriesGroup(
                        model: model, entries: model.currentEntries, sectionName: model.currentDestination.name,
                        emptyText: emptyText, isExpanded: $loggedExpanded, revealedEntryID: $revealedEntryID,
                        open: { sheet = .entry($0.id) })
                    if model.selectedMeal != nil {
                        MealChooser(model: model)
                        MealCard(model: model)
                    } else {
                        NoMealsCard(
                            destinationName: model.currentDestination.name,
                            canLoadDemo: model.catalog != nil && model.activeMeals.isEmpty,
                            createMeal: { sheet = .newMeal },
                            loadDemo: { Task { await loadDemo() } })
                    }
                }
                .padding(.bottom, Spacing.xs)
    }

    private var emptyText: String {
        let destination = model.currentDestination
        let day = model.isViewingToday ? "today" : "on this day"
        if !model.hasSections || destination.isUnsectioned { return "Nothing logged \(day) yet." }
        return "Nothing logged in \(destination.name) \(day) yet."
    }

    private func loadDemo() async {
        do {
            try await model.loadDemoRoutine()
        } catch {
            model.errorMessage = "Couldn’t load the demo routine. \(error.localizedDescription)"
        }
    }

    private var header: some View {
        let destinations = model.destinations
        let index = model.currentDestinationIndex
        let destination = model.currentDestination
        let canBrowse = destinations.count > 1

        return HStack(alignment: .center, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.s) {
                    Caption(positionText(destination: destination, index: index, count: destinations.count))
                    if model.hasSections {
                        HStack(spacing: 3) {
                            ForEach(destinations.indices, id: \.self) { i in
                                Capsule()
                                    .fill(i == index ? Palette.accent : Palette.handle)
                                    .frame(width: i == index ? 14 : 6, height: 4)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 16)
                if model.hasSections {
                    Button { sheet = .sections } label: {
                        HStack(spacing: 6) {
                            Text(destination.name)
                                .font(Typeface.title1)
                                .tracking(-0.5)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.down")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                        }
                        .frame(minHeight: Metrics.tapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(destination.name), section \(index + 1) of \(destinations.count)")
                    .accessibilityHint("Shows all sections")
                } else {
                    Text(destination.name)
                        .font(Typeface.title1)
                        .tracking(-0.5)
                        .frame(minHeight: Metrics.tapTarget)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Spacer(minLength: 0)
            if canBrowse {
                HStack(spacing: 6) {
                    Button { withAnimation(.snappy) { model.browseDestinations(by: -1) } } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Previous section: \(destinations[(index - 1 + destinations.count) % destinations.count].name)")
                    Button { withAnimation(.snappy) { model.browseDestinations(by: 1) } } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Next section: \(destinations[(index + 1) % destinations.count].name)")
                }
            }
        }
        .padding(.leading, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .padding(.bottom, Spacing.s)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard canBrowse, abs(value.translation.height) > 36,
                    abs(value.translation.height) > abs(value.translation.width)
                else { return }
                withAnimation(.snappy) { model.browseDestinations(by: value.translation.height < 0 ? 1 : -1) }
            }
        )
    }

    private func positionText(destination: Destination, index: Int, count: Int) -> String {
        if !model.hasSections { return "No sections" }
        if destination.isUnsectioned { return "Outside your sections" }
        return "Section \(index + 1) of \(count)"
    }
}

struct MealChooser: View {
    let model: DiaryModel

    var body: some View {
        let meals = model.currentMeals
        let selected = model.selectedMeal?.id
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Caption(label)
                Spacer()
                if let index = model.selectedMealIndex {
                    Text("\(index + 1) of \(meals.count)")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.horizontal, 4)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(meals) { meal in
                            Button(meal.name) { model.selectMeal(id: meal.id) }
                                .buttonStyle(ChipButtonStyle(isSelected: meal.id == selected))
                                .accessibilityAddTraits(meal.id == selected ? .isSelected : [])
                                .id(meal.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.horizontal, -10)
                .onChange(of: selected) { _, id in
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var label: String {
        let destination = model.currentDestination
        if destination.isUnsectioned || !model.hasSections { return "All saved meals" }
        return model.currentUsesAllMeals ? "All saved meals · none assigned" : "Usual for \(destination.name)"
    }
}

struct NoMealsCard: View {
    let destinationName: String
    let canLoadDemo: Bool
    let createMeal: () -> Void
    let loadDemo: () -> Void

    @ViewBuilder
    private var actions: some View {
        Button("Create a saved meal", action: createMeal)
            .buttonStyle(SecondaryButtonStyle())
        if canLoadDemo {
            Button("Load demo routine", action: loadDemo)
                .buttonStyle(TextButtonStyle())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption("No saved meals yet")
            Text("Save the meals you eat most, and they’ll be waiting here, ready to log.")
                .font(Typeface.sans(20, .semibold, relativeTo: .title3))
            Text("Until then, Add food logs anything into \(destinationName). You can save a meal from any entry later.")
                .font(Typeface.sans(14, relativeTo: .subheadline))
                .foregroundStyle(Palette.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { actions }
                VStack(alignment: .leading, spacing: Spacing.s) { actions }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
