import InstalogCore
import SwiftUI
import UIKit

struct TodayView: View {
    let model: DiaryModel
    @Binding var sheet: ActiveSheet?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            if typeSize.isAccessibilitySize {
                // Large text: the whole screen scrolls so nothing is squeezed out of view.
                ScrollView {
                    VStack(spacing: 0) {
                        top
                        SectionCard(model: model, sheet: $sheet, scrollsInternally: false)
                            .padding(.horizontal, Spacing.s)
                            .padding(.top, Spacing.m)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                top
                SectionCard(model: model, sheet: $sheet)
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
    }

    private var top: some View {
        VStack(spacing: 0) {
            header
            if !model.isViewingToday { pastDayBanner }
            SummaryHeader(model: model, openDetails: { sheet = .nutrients })
                .padding(.horizontal, Spacing.l)
                .padding(.top, 6)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Button { sheet = .day } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(Format.dayHeading(model.viewedDate, today: model.today))
                        .font(Typeface.title2)
                        .tracking(-0.4)
                    Text(Format.dayStamp(model.viewedDate))
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
                Button { Task { await model.showAdjacentDay(-1) } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(JoinedIconButtonStyle(leading: true))
                    .accessibilityLabel("Previous day")
                Button { Task { await model.showAdjacentDay(1) } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(JoinedIconButtonStyle(leading: false))
                    .disabled(!model.canShowNextDay)
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

    private var pastDayBanner: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Past day · logging goes to \(Format.shortDay(model.viewedDate))")
                .font(Typeface.subhead)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Today") { Task { await model.changeDate(to: model.today) } }
                .buttonStyle(TextButtonStyle())
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, 2)
        .frame(minHeight: Metrics.tapTarget)
        .background(Palette.accentSurface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Palette.accentBorder))
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
        return Button {
            Task {
                if await model.logSelectedMeal() {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
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
                        .foregroundStyle(Palette.onAccentDim)
                }
            } else {
                // A past day is named on the button itself, so it's never logged into by accident.
                VStack(spacing: 0) {
                    Text(logLabel).lineLimit(2)
                    Text("\(Format.shortDay(model.viewedDate)) · \(energy) kcal")
                        .font(Typeface.sans(13, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Palette.onAccentDim)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
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
            ToastView(toast: toast, undo: { Task { await model.undo(toast) } }, dismiss: { dismissToast(toast) })
                .padding(.horizontal, Spacing.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    UIAccessibility.post(notification: .announcement, argument: toast.message)
                    // VoiceOver users get as long as they need; the toast stays until dismissed.
                    guard !UIAccessibility.isVoiceOverRunning else { return }
                    try? await Task.sleep(for: .seconds(5))
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
    let toast: Toast
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "checkmark")
                .font(.system(.body, weight: .bold))
                .foregroundStyle(Palette.toastAction)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(Typeface.sans(15, .medium, relativeTo: .subheadline))
                .frame(maxWidth: .infinity, alignment: .leading)
            if toast.undo != nil {
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
