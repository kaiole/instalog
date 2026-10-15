import InstalogCore
import SwiftUI
import UIKit

struct TodayView: View {
    let model: DiaryModel
    @Binding var sheet: ActiveSheet?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// While the keyboard is up the summary shrinks to one line, so the meal being edited stays in view.
    @State private var keyboardVisible = false
    /// Navigation waiting on a Save / Discard choice for an unsaved entry edit.
    @State private var pendingLeave: PendingLeave?

    var body: some View {
        VStack(spacing: 0) {
            if typeSize.isAccessibilitySize {
                // Large text: the whole screen scrolls so nothing is squeezed out of view.
                ScrollView {
                    VStack(spacing: 0) {
                        top
                        SectionCard(model: model, sheet: $sheet, guardEdit: guardEdit, scrollsInternally: false)
                            .padding(.horizontal, Spacing.s)
                            .padding(.top, Spacing.m)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                top
                SectionCard(model: model, sheet: $sheet, guardEdit: guardEdit)
                    .padding(.horizontal, Spacing.s)
                    .padding(.top, Spacing.m)
            }
            bottomBar
                .overlay(alignment: .top) {
                    toast.alignmentGuide(.top) { $0[.bottom] + Spacing.s }
                }
        }
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.text)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            // A hardware keyboard only shows the Done bar; only collapse for the on-screen keyboard.
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            withAnimation(.snappy) { keyboardVisible = (frame?.height ?? 0) > 120 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy) { keyboardVisible = false }
        }
        .confirmationDialog(
            pendingLeave?.title ?? "", isPresented: Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } }),
            titleVisibility: .visible, presenting: pendingLeave
        ) { pending in
            Button("Save") {
                Task {
                    do {
                        try await model.saveEntryEdit()
                        model.endEditing()
                        pending.action()
                    } catch {
                        model.errorMessage = "Couldn’t save changes. \(error.localizedDescription)"
                    }
                }
            }
            Button("Discard changes", role: .destructive) {
                model.endEditing()
                pending.action()
            }
            Button("Keep editing", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    /// Runs `action` now, or after the user saves or discards an unsaved entry edit.
    private func guardEdit(_ action: @escaping () -> Void) {
        guard let edit = model.entryEdit, edit.hasChanges else { return action() }
        pendingLeave = PendingLeave(edit: edit, action: action)
    }

    private var top: some View {
        VStack(spacing: 0) {
            header
            if !keyboardVisible || typeSize.isAccessibilitySize {
                if !model.isViewingToday { dayBanner }
                SummaryHeader(model: model, openDetails: { sheet = .nutrients })
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                CompactSummary(model: model)
                    .padding(.horizontal, Spacing.l)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Button { guardEdit { sheet = .day } } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(Format.dayHeading(model.viewedDate, today: model.today))
                        .font(Typeface.title2)
                        .tracking(-0.4)
                    Text(Format.dayStamp(model.viewedDate, today: model.today))
                        .font(Typeface.numFootnote)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose day. Showing \(Format.dayHeading(model.viewedDate, today: model.today)), \(Format.shortDay(model.viewedDate))")
            HStack(spacing: 2) {
                Button { guardEdit { Task { await model.showAdjacentDay(-1) } } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(JoinedIconButtonStyle(leading: true))
                    .accessibilityLabel("Previous day")
                Button { guardEdit { Task { await model.showAdjacentDay(1) } } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(JoinedIconButtonStyle(leading: false))
                    .accessibilityLabel("Next day")
            }
            Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(IconButtonStyle(background: .clear, foreground: Palette.secondary))
                .accessibilityLabel("Settings")
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.top, Spacing.s)
    }

    /// Past days say where logging goes; future days are marked as planned, with a dashed edge
    /// (dashed means "not real yet" throughout).
    private var dayBanner: some View {
        let future = model.isViewingFuture
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        return HStack(spacing: Spacing.s) {
            Image(systemName: future ? "calendar.badge.clock" : "clock.arrow.circlepath")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(future
                ? "Planned · \(Format.shortDay(model.viewedDate)) hasn’t happened yet"
                : "Past day · logging goes to \(Format.shortDay(model.viewedDate))")
                .font(Typeface.subhead)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Today") { guardEdit { Task { await model.changeDate(to: model.today) } } }
                .buttonStyle(TextButtonStyle())
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, 2)
        .frame(minHeight: Metrics.tapTarget)
        .background(Palette.accentSurface, in: shape)
        .overlay(shape.stroke(Palette.accentBorder, style: StrokeStyle(lineWidth: 1, dash: future ? [4, 3] : [])))
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let previous = model.previousLogOfSelectedMeal, model.toast == nil {
                Label(
                    "Already logged at \(Format.time(previous.recordedAt)). Logging again adds another entry.",
                    systemImage: "info.circle"
                )
                .font(Typeface.footnote)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, Spacing.xs)
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: Spacing.s) { actions(fillsWidth: true) }
            } else {
                HStack(spacing: Spacing.s) { actions(fillsWidth: false) }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder
    private func actions(fillsWidth: Bool) -> some View {
        if model.selectedMeal != nil {
            Button(action: openAddFood) {
                Label("Add food", systemImage: "plus")
                    .labelStyle(CompactLabelStyle())
            }
            .buttonStyle(SecondaryButtonStyle(fillsWidth: fillsWidth))
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            logButton.layoutPriority(1)
        } else {
            Button(action: openAddFood) {
                Label(model.hasSections ? "Add food to \(model.currentDestination.name)" : "Add food", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var logButton: some View {
        let energy = NumberFormatting.energy(model.draftNutrition[.energy].known)
        let editing = model.entryEdit?.hasChanges == true
        return Button {
            // Drop focus first so no field is left editing a draft that's about to reset.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            guardEdit {
                Task {
                    if await model.logSelectedMeal() {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
        } label: {
            if model.isViewingToday {
                HStack(spacing: Spacing.s) {
                    if model.isLogging { ProgressView().tint(Palette.onAccent) }
                    Text(logLabel).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).minimumScaleFactor(0.85)
                    Spacer(minLength: Spacing.xs)
                    Text(energy)
                        .font(Typeface.mono(15, .semibold, relativeTo: .headline))
                        .foregroundStyle(editing ? Palette.secondary : Palette.onAccentDim)
                }
            } else {
                // A past day is named on the button itself, so it's never logged into by accident.
                VStack(spacing: 0) {
                    Text(logLabel).lineLimit(2)
                    Text("\(Format.shortDay(model.viewedDate)) · \(energy) kcal")
                        .font(Typeface.sans(13, .medium, relativeTo: .subheadline))
                        .foregroundStyle(editing ? Palette.secondary : Palette.onAccentDim)
                }
            }
        }
        // While an entry has unsaved changes, its Save is the one lime button on screen.
        .buttonStyle(PrimaryButtonStyle(muted: editing))
        .disabled(model.isLogging || !model.draftItems.contains { $0.quantity > 0 })
        .accessibilityLabel(
            "\(logLabel)\(model.isViewingToday ? "" : " on \(Format.shortDay(model.viewedDate))"), \(energy) calories")
    }

    private var logLabel: String {
        let verb = model.previousLogOfSelectedMeal == nil ? "Log" : "Log again"
        return model.hasSections ? "\(verb) to \(model.currentDestination.name)" : verb
    }

    private func openAddFood() {
        sheet = .addFood(destinationID: model.currentDestination.id, date: model.viewedDate)
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = model.toast {
            ToastView(
                message: toast.message, undo: toast.undo == nil ? nil : { Task { await model.undo(toast) } },
                dismiss: { dismissToast(toast) })
                .padding(.horizontal, Spacing.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    UIAccessibility.post(notification: .announcement, argument: toast.message)
                    // VoiceOver users get as long as they need; the toast stays until dismissed.
                    guard !UIAccessibility.isVoiceOverRunning else { return }
                    try? await Task.sleep(for: .seconds(6))
                    dismissToast(toast)
                }
        }
    }

    private func dismissToast(_ toast: Toast) {
        if model.toast?.id == toast.id {
            withAnimation { model.toast = nil }
        }
    }
}

/// The previous/next day pair: two icon buttons sharing one rounded outline.
private struct JoinedIconButtonStyle: ButtonStyle {
    let leading: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: leading ? Radius.m : 4, bottomLeadingRadius: leading ? Radius.m : 4,
            bottomTrailingRadius: leading ? 4 : Radius.m, topTrailingRadius: leading ? 4 : Radius.m, style: .continuous)
        configuration.label
            .font(.system(.body, weight: .semibold))
            .frame(minWidth: Metrics.tapTarget, minHeight: Metrics.tapTarget)
            .foregroundStyle(isEnabled ? Palette.text : Palette.disabled)
            .background(Palette.control, in: shape)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct ToastView: View {
    let message: String
    /// Shows an Undo button when set.
    let undo: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "checkmark")
                .font(.system(.body, weight: .bold))
                .foregroundStyle(Palette.toastAction)
                .accessibilityHidden(true)
            Text(message)
                .font(Typeface.sans(15, .medium, relativeTo: .subheadline))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo {
                Button(action: undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(Typeface.sans(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Palette.toastAction)
                        .padding(.horizontal, 14)
                        .frame(minHeight: Metrics.tapTarget)
                        .background(Palette.text, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Palette.onToast)
        .padding(.leading, Spacing.l)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(Palette.toast, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, dismiss)
    }
}

/// Icon and title with tighter spacing than the system label.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// A navigation held back until an unsaved entry edit is saved or discarded.
private struct PendingLeave {
    let title: String
    let message: String
    let action: () -> Void

    @MainActor
    init(edit: EntryEdit, action: @escaping () -> Void) {
        title = "Save changes to \(edit.draft.name)?"
        let changed = edit.draft.foods.filter { food in
            edit.original.foods.first { $0.id == food.id }?.quantity != food.quantity
        }.count + edit.original.foods.filter { food in !edit.draft.foods.contains { $0.id == food.id } }.count
        let delta = NutritionCalculator.summarize(edit.draft)[.energy].known
            - NutritionCalculator.summarize(edit.original)[.energy].known
        var message = changed == 1 ? "You changed 1 food" : "You changed \(changed) foods"
        if changed == 0 { message = "You renamed this entry" }
        if abs(delta) >= 0.5 { message += " · \(SummaryPreview.signed(delta, unit: .kilocalorie)) kcal" }
        self.message = message
        self.action = action
    }
}
