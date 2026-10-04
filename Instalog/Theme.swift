import CoreText
import InstalogCore
import SwiftUI

/// Design tokens from the approved design canvas (dark, Geist / Geist Mono, lime accent).
/// Views never use hex values directly; every color they need is named here.
enum Palette {
    // Surfaces, darkest to lightest.
    static let background = Color(hex: 0x0B0D0F)
    static let surface = Color(hex: 0x14171A)
    static let sheet = Color(hex: 0x16191D)
    /// Cards, form groups and rows.
    static let raised = Color(hex: 0x1A1E22)
    static let control = Color(hex: 0x1F2428)
    /// Count badges and the selected row in pickers.
    static let badge = Color(hex: 0x262C31)

    // Lines.
    static let border = Color(hex: 0x20252A)
    static let divider = Color(hex: 0x262B30)
    static let outline = Color(hex: 0x2E343A)
    static let handle = Color(hex: 0x3A4148)

    // Text. Tertiary passes 4.5:1 on every surface up to `control`.
    static let text = Color(hex: 0xEEF1F3)
    static let secondary = Color(hex: 0xA3ACB4)
    static let tertiary = Color(hex: 0x87909A)
    /// Disabled controls only, never for readable text.
    static let disabled = Color(hex: 0x5F6870)

    static let accent = Color(hex: 0xC8F25A)
    static let onAccent = Color(hex: 0x10140A)
    static let onAccentDim = Color(hex: 0x3A4A10)
    static let accentBorder = Color(hex: 0x4A5A22)
    /// Focused fields and the past-day banner.
    static let accentSurface = Color(hex: 0x1D2410)

    static let danger = Color(hex: 0xD42F35)
    static let onDanger = Color.white
    static let dangerText = Color(hex: 0xFF8A7E)
    static let dangerSurface = Color(hex: 0x2A1614)

    /// Over an energy target, or past a limit.
    static let over = Color(hex: 0xFF9466)
    static let overSurface = Color(hex: 0x2B1A12)

    static let toast = Color(hex: 0xDDE3E7)
    static let onToast = Color(hex: 0x0B0D0F)
    static let toastAction = Color(hex: 0x2C5200)

    static func nutrientColor(_ id: NutrientID) -> Color {
        switch id {
        case .protein: Color(hex: 0x6CB8FF)
        case .carbohydrate: Color(hex: 0xFFB54D)
        case .fat: Color(hex: 0xA98BFF)
        case .fiber: Color(hex: 0x4FD1A5)
        case .sugars, .addedSugars: Color(hex: 0xFF8FB1)
        case .sodium, .potassium: Color(hex: 0x7ADFE8)
        case .saturatedFat: Color(hex: 0xC59BFF)
        default: Color(hex: 0xF2D45C)
        }
    }
}

/// Spacing scale. The screen gutter is `l`; blocks inside a card are `m` apart; form groups `xl`.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii, always used with `.continuous` corners.
enum Radius {
    /// Badges and pills.
    static let s: CGFloat = 8
    /// Icon buttons, the stepper, fields and segmented controls.
    static let m: CGFloat = 14
    /// Buttons, cards, form groups and the toast.
    static let l: CGFloat = 18
    /// The section card and sheet corners (l + the card's 8 pt inset).
    static let xl: CGFloat = 26
}

/// Minimum heights for controls.
enum Metrics {
    static let tapTarget: CGFloat = 44
    static let button: CGFloat = 52
    static let formRow: CGFloat = 52
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Geist with Dynamic Type scaling. Falls back to the system font if registration failed.
enum Typeface {
    static func registerBundledFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(sansName(weight), size: size, relativeTo: style)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(monoName(weight), size: size, relativeTo: style)
    }

    // Type scale. Every token scales with Dynamic Type relative to the listed text style.
    static var display: Font { mono(34, .semibold, relativeTo: .largeTitle) }
    static var title1: Font { sans(28, .semibold, relativeTo: .title) }
    static var title2: Font { sans(22, .semibold, relativeTo: .title2) }
    static var title3: Font { sans(20, .semibold, relativeTo: .title3) }
    static var numLarge: Font { mono(26, .semibold, relativeTo: .title2) }
    static var headline: Font { sans(16, .semibold, relativeTo: .headline) }
    static var body: Font { sans(15, relativeTo: .body) }
    static var bodyMedium: Font { sans(15, .medium, relativeTo: .body) }
    static var numBody: Font { mono(15, .semibold, relativeTo: .body) }
    static var callout: Font { sans(14, .medium, relativeTo: .callout) }
    static var calloutStrong: Font { sans(14, .semibold, relativeTo: .callout) }
    static var numCallout: Font { mono(14, .medium, relativeTo: .callout) }
    static var subhead: Font { sans(13, relativeTo: .subheadline) }
    static var footnote: Font { sans(12, relativeTo: .footnote) }
    static var numFootnote: Font { mono(12, relativeTo: .footnote) }
    static var caption: Font { mono(11, relativeTo: .caption2) }

    private static func sansName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "Geist-Bold"
        case .semibold: "Geist-SemiBold"
        case .medium: "Geist-Medium"
        default: "Geist-Regular"
        }
    }

    private static func monoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black, .semibold: "GeistMono-SemiBold"
        case .medium: "GeistMono-Medium"
        default: "GeistMono-Regular"
        }
    }
}

/// Small uppercase mono label used for section captions.
struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Typeface.caption)
            .tracking(0.88)
            .foregroundStyle(Palette.tertiary)
    }
}

struct IconButtonStyle: ButtonStyle {
    var background: Color = Palette.control
    var foreground: Color = Palette.text
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .frame(minWidth: Metrics.tapTarget, minHeight: Metrics.tapTarget)
            .foregroundStyle(isEnabled ? foreground : Palette.disabled)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.headline)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .frame(minHeight: Metrics.button)
            .frame(maxWidth: .infinity)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.headline)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 18)
            .frame(minHeight: Metrics.button)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.headline)
            .foregroundStyle(Palette.dangerText)
            .padding(.horizontal, 18)
            .frame(minHeight: Metrics.button)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(Palette.dangerSurface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// Lime text button, for inline actions like Reset or "Show all".
struct TextButtonStyle: ButtonStyle {
    var color: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.calloutStrong)
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.s)
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.callout)
            .lineLimit(1)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: Metrics.tapTarget)
            .foregroundStyle(isSelected ? Palette.background : Palette.text)
            .background(isSelected ? Palette.text : Palette.control, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A two-to-four option switch on a control track, matching the design (the system one can't be restyled).
struct SegmentedControl<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(isOn ? Typeface.calloutStrong : Typeface.callout)
                        .foregroundStyle(isOn ? Palette.text : Palette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(isOn ? Palette.handle : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

/// The one sheet header: optional back, title with subtitle, extra trailing controls, close.
struct SheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var back: (() -> Void)?
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            if let back {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(foreground: Palette.secondary))
                    .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typeface.title2)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Typeface.subhead)
                        .foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(foreground: Palette.secondary))
                .accessibilityLabel("Close")
        }
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, close: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, back: back, close: close, trailing: { EmptyView() })
    }
}

/// A group of form rows on `raised`, separated by inset dividers.
struct FormGroup<Content: View>: View {
    var caption: String?
    var trailingCaption: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if caption != nil || trailingCaption != nil {
                HStack {
                    if let caption { Caption(caption) }
                    Spacer()
                    if let trailingCaption { Caption(trailingCaption) }
                }
                .padding(.horizontal, Spacing.xs)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content() }
            }
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            if let footnote {
                Text(footnote)
                    .font(Typeface.footnote)
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.top, -Spacing.xs)
            }
        }
    }
}

private struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Spacing.l)
            }
        }
    }
}

/// One form row: label on the left, value or control on the right, at least 52 pt tall.
struct FormRow<Trailing: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the value moves under the label, so neither gets truncated.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Spacing.m))
        layout {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(label).font(Typeface.body).foregroundStyle(Palette.text)
                if let detail {
                    Text(detail).font(Typeface.footnote).foregroundStyle(Palette.secondary)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
            trailing()
        }
        .padding(.vertical, typeSize.isAccessibilitySize ? Spacing.s : 0)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: Metrics.formRow)
    }
}

/// A number field row: label, mono value (tertiary "unknown" when blank) and unit.
struct NumberFormRow: View {
    let label: String
    @Binding var text: String
    let unit: String
    var placeholder = Format.unknown
    var isAcceptable: (String) -> Bool = QuantityInput.isAcceptableEditing

    var body: some View {
        FormRow(label: label) {
            ZStack(alignment: .trailing) {
                if text.isEmpty {
                    Text(placeholder).font(Typeface.numCallout).foregroundStyle(Palette.tertiary)
                        .accessibilityHidden(true)
                }
                DecimalField(text: $text, accessibilityLabel: "\(label) in \(unit)", isAcceptable: isAcceptable)
            }
            Text(unit)
                .font(Typeface.subhead)
                .foregroundStyle(Palette.tertiary)
                .frame(minWidth: 28, alignment: .leading)
        }
    }
}

/// Shows "incomplete" without relying on color.
struct IncompleteMark: View {
    var body: some View {
        Image(systemName: "circle.dashed")
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(Palette.secondary)
            .accessibilityLabel("incomplete data")
    }
}

extension View {
    func cardBackground(_ color: Color = Palette.raised, radius: CGFloat = Radius.l) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

enum Format {
    /// The one word for a value no logged food reports.
    static let unknown = "unknown"

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Today", "Yesterday", a weekday within the past week, otherwise a date ("Sep 10").
    static func dayHeading(_ date: LogDate, today: LogDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: -1) { return "Yesterday" }
        if date == today.adding(days: 1) { return "Tomorrow" }
        if date < today, date >= today.adding(days: -6) {
            return date.startOfDay().formatted(.dateTime.weekday(.wide))
        }
        return date.startOfDay().formatted(.dateTime.month(.abbreviated).day())
    }

    /// A unit name short enough for a stepper: USDA portions like
    /// "medium (7\" to 7-7/8\" long)" become "medium". Full names stay in the unit menu.
    static func unitName(_ label: String) -> String {
        var name = label
        if let cut = name.firstIndex(where: { $0 == "(" || $0 == "," }) { name = String(name[..<cut]) }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = label }
        return name.count > 12 ? String(name.prefix(11)) + "…" : name
    }

    /// The small caps stamp beside the day title. When the title is already a date, only the weekday.
    static func dayStamp(_ date: LogDate, today: LogDate) -> String {
        let heading = dayHeading(date, today: today)
        let weekday = date.startOfDay().formatted(.dateTime.weekday(.wide))
        if heading != "Today", heading != "Yesterday", heading != "Tomorrow", heading != weekday {
            return date.startOfDay().formatted(.dateTime.weekday(.abbreviated)).uppercased()
        }
        return dayStamp(date)
    }

    static func dayStamp(_ date: LogDate) -> String {
        date.startOfDay().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
            .replacingOccurrences(of: ",", with: " ·")
    }

    /// "Tue 30 Sep" style, for labels that must name a day compactly.
    static func shortDay(_ date: LogDate) -> String {
        date.startOfDay().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The number alone ("12"), "0" when nothing is logged, or "unknown".
    static func amount(_ total: NutrientTotal, unit: NutrientUnit) -> String {
        if total.completeness == .empty { return "0" }
        guard let value = total.displayAmount else { return unknown }
        return unit == .kilocalorie ? NumberFormatting.energy(value) : NumberFormatting.nutrient(value)
    }

    /// The number with its unit, spaced ("12 g", "433 kcal"), or "unknown".
    static func amountWithUnit(_ total: NutrientTotal, unit: NutrientUnit) -> String {
        if total.completeness == .empty { return NumberFormatting.nutrient(0, unit: unit) }
        guard let value = total.displayAmount else { return unknown }
        return NumberFormatting.nutrient(value, unit: unit)
    }

    static func energy(_ value: Double?) -> String {
        value.map { "\(NumberFormatting.energy($0)) kcal" } ?? unknown
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        n == 1 ? "1 \(singular)" : "\(n) \(plural ?? singular + "s")"
    }

    static func completenessNote(_ total: NutrientTotal) -> String? {
        switch total.completeness {
        case .partial: "\(total.reportingFoods) of \(total.totalFoods) foods report this; total is incomplete"
        case .unknown: "No logged food reports this"
        case .complete, .empty: nil
        }
    }
}

/// Centered icon, title, message and an optional action, for empty, missing and error states.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Palette.tertiary)
                .frame(width: 56, height: 56)
                .background(Palette.control, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.headline)
                .foregroundStyle(Palette.text)
                .padding(.top, Spacing.xs)
            if let message {
                Text(message)
                    .font(Typeface.subhead)
                    .foregroundStyle(Palette.secondary)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Trailing swipe for rows outside a List: swipe left to reveal an 88 pt destructive action,
/// or swipe all the way to run it. VoiceOver gets the same action by name.
struct SwipeAction: ViewModifier {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    @State private var revealed = false
    @GestureState private var drag: CGFloat = 0
    private let width: CGFloat = 88
    private let full: CGFloat = 200

    func body(content: Content) -> some View {
        let offset = isEnabled ? min(0, max(-full - 20, (revealed ? -width : 0) + drag)) : 0
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button(role: .destructive, action: run) {
                    VStack(spacing: 3) {
                        Image(systemName: systemImage)
                        Text(title).font(Typeface.sans(13, .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(Palette.onDanger)
                    .frame(width: max(width, -offset))
                    .frame(maxHeight: .infinity)
                    .background(Palette.danger)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            content
                .background(Palette.raised)
                .offset(x: offset)
                .animation(.easeOut(duration: 0.2), value: revealed)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .updating($drag) { value, state, _ in
                    if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
                }
                .onEnded { value in
                    guard isEnabled, abs(value.translation.width) > abs(value.translation.height) else { return }
                    let final = (revealed ? -width : 0) + value.translation.width
                    if final < -full { run() } else { revealed = final < -width / 2 }
                }
        )
        .accessibilityAction(named: title) { if isEnabled { run() } }
    }

    private func run() {
        revealed = false
        action()
    }
}

extension View {
    func swipeAction(_ title: String, systemImage: String = "trash", isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(SwipeAction(title: title, systemImage: systemImage, isEnabled: isEnabled, action: action))
    }
}
