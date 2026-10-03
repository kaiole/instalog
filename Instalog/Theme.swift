import CoreText
import InstalogCore
import SwiftUI

/// Design tokens from the design canvas (dark, Geist / Geist Mono, lime accent).
enum Palette {
    static let background = Color(hex: 0x0B0D0F)
    static let surface = Color(hex: 0x14171A)
    static let raised = Color(hex: 0x1A1E22)
    static let row = Color(hex: 0x1C2024)
    static let control = Color(hex: 0x1F2428)
    static let sheet = Color(hex: 0x16191D)
    static let border = Color(hex: 0x20252A)
    static let divider = Color(hex: 0x262B30)
    static let outline = Color(hex: 0x2E343A)
    static let handle = Color(hex: 0x3A4148)

    static let text = Color(hex: 0xEEF1F3)
    static let secondary = Color(hex: 0xA3ACB4)
    static let tertiary = Color(hex: 0x7D868F)

    static let accent = Color(hex: 0xC8F25A)
    static let onAccent = Color(hex: 0x10140A)
    static let onAccentDim = Color(hex: 0x3A4A10)
    static let accentBorder = Color(hex: 0x4A5A22)
    static let success = Color(hex: 0x2C5200)

    static let danger = Color(hex: 0xD42F35)
    static let dangerText = Color(hex: 0xFF8A7E)
    static let dangerSurface = Color(hex: 0x2A1614)

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
            .font(Typeface.mono(11, relativeTo: .caption2))
            .tracking(0.9)
            .foregroundStyle(Palette.tertiary)
    }
}

struct IconButtonStyle: ButtonStyle {
    var background: Color = Palette.control
    var foreground: Color = Palette.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.sans(16, .semibold, relativeTo: .headline))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .frame(maxWidth: .infinity)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.sans(15, .semibold, relativeTo: .headline))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(Palette.control, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.sans(14, .medium, relativeTo: .subheadline))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(isSelected ? Palette.background : Palette.text)
            .background(isSelected ? Palette.text : Palette.control, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A sheet header with a title and a close button.
struct SheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typeface.sans(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(Palette.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Typeface.sans(13, relativeTo: .footnote))
                        .foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(foreground: Palette.secondary))
            .accessibilityLabel("Close")
        }
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, close: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, close: close, trailing: { EmptyView() })
    }
}

/// Shows "incomplete" without relying on color.
struct IncompleteMark: View {
    var body: some View {
        Image(systemName: "circle.dashed")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Palette.secondary)
            .accessibilityLabel("incomplete data")
    }
}

extension View {
    func cardBackground(_ color: Color = Palette.raised, radius: CGFloat = 22) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

enum Format {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayHeading(_ date: LogDate, today: LogDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: -1) { return "Yesterday" }
        if date == today.adding(days: 1) { return "Tomorrow" }
        return date.startOfDay().formatted(.dateTime.weekday(.wide))
    }

    static func dayStamp(_ date: LogDate) -> String {
        date.startOfDay().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
            .replacingOccurrences(of: ",", with: " ·")
    }

    static func amount(_ total: NutrientTotal, unit: NutrientUnit) -> String {
        guard let value = total.displayAmount else { return "—" }
        return unit == .kilocalorie ? NumberFormatting.energy(value) : NumberFormatting.nutrient(value)
    }

    static func completenessNote(_ total: NutrientTotal) -> String? {
        switch total.completeness {
        case .partial: "\(total.reportingFoods) of \(total.totalFoods) foods report this; total is incomplete"
        case .unknown: "No logged food reports this"
        case .complete, .empty: nil
        }
    }
}
