import SwiftUI
import UIKit

// MARK: - Color(hex:) Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            // Invalid hex string — fall back to an obvious neutral gray
            // rather than near-black RGB(1, 1, 1).
            (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - App Theme

enum AppTheme: String, CaseIterable, Identifiable {
    case midnight = "Midnight"
    case felt = "Felt"
    case classic = "Classic"

    var id: String { rawValue }

    static var current: AppTheme {
        ThemeManager.shared.theme
    }

    var description: String {
        switch self {
        case .midnight: return "Dark blue base"
        case .felt: return "Casino table green"
        case .classic: return "Navy & charcoal"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .midnight: return .midnight
        case .felt: return .felt
        case .classic: return .classic
        }
    }
}

// MARK: - Theme Palette

struct ThemePalette {
    let backgroundPrimary: Color
    let backgroundSecondary: Color
    let cardSurface: Color
    let feltGreen: Color
    let goldAccent: Color
    let chipRed: Color
    let chipBlue: Color
    let userBubble: Color
    let aiBubble: Color
    let textPrimary: Color
    let textSecondary: Color
    let mZoneGreen: Color
    let mZoneYellow: Color
    let mZoneOrange: Color
    let mZoneRed: Color
    let borderSubtle: Color

    // MARK: - Midnight (original)

    static let midnight = ThemePalette(
        backgroundPrimary: Color(hex: "0A0E14"),
        backgroundSecondary: Color(hex: "131820"),
        cardSurface: Color(hex: "1A2030"),
        feltGreen: Color(hex: "1B5E20"),
        goldAccent: Color(hex: "FFD54F"),
        chipRed: Color(hex: "E53935"),
        chipBlue: Color(hex: "1E88E5"),
        userBubble: Color(hex: "1B5E20"),
        aiBubble: Color(hex: "2A2D35"),
        textPrimary: Color(hex: "E8EAED"),
        textSecondary: Color(hex: "9AA0A6"),
        mZoneGreen: Color(hex: "4CAF50"),
        mZoneYellow: Color(hex: "FFC107"),
        mZoneOrange: Color(hex: "FF9800"),
        mZoneRed: Color(hex: "F44336"),
        borderSubtle: Color.white.opacity(0.08)
    )

    // MARK: - Felt (casino green)

    static let felt = ThemePalette(
        backgroundPrimary: Color(hex: "0A1F15"),
        backgroundSecondary: Color(hex: "112B1E"),
        cardSurface: Color(hex: "1B4332"),
        feltGreen: Color(hex: "1B4332"),
        goldAccent: Color(hex: "D4A843"),
        chipRed: Color(hex: "EF4444"),
        chipBlue: Color(hex: "2DD4BF"),
        userBubble: Color(hex: "22543D"),
        aiBubble: Color(hex: "1A2E24"),
        textPrimary: Color(hex: "F8FAFC"),
        textSecondary: Color(hex: "94A3B8"),
        mZoneGreen: Color(hex: "22C55E"),
        mZoneYellow: Color(hex: "FBBF24"),
        mZoneOrange: Color(hex: "F97316"),
        mZoneRed: Color(hex: "EF4444"),
        borderSubtle: Color.white.opacity(0.10)
    )

    // MARK: - Classic (navy & charcoal)

    static let classic = ThemePalette(
        backgroundPrimary: Color(hex: "0F172A"),
        backgroundSecondary: Color(hex: "1A1A2E"),
        cardSurface: Color(hex: "1E293B"),
        feltGreen: Color(hex: "1B4332"),
        goldAccent: Color(hex: "D4A843"),
        chipRed: Color(hex: "EF4444"),
        chipBlue: Color(hex: "2DD4BF"),
        userBubble: Color(hex: "1B4332"),
        aiBubble: Color(hex: "1E293B"),
        textPrimary: Color(hex: "F8FAFC"),
        textSecondary: Color(hex: "94A3B8"),
        mZoneGreen: Color(hex: "22C55E"),
        mZoneYellow: Color(hex: "FBBF24"),
        mZoneOrange: Color(hex: "F97316"),
        mZoneRed: Color(hex: "EF4444"),
        borderSubtle: Color.white.opacity(0.10)
    )
}

// MARK: - Theme Manager

/// Observable source of truth for the active theme. View bodies that read any
/// themed color (e.g. `Color.backgroundPrimary`) register an Observation
/// dependency through `ThemeManager.shared` and re-render when the theme
/// changes — no view-hierarchy reset needed.
///
/// `@unchecked Sendable`: `theme` is a value-type enum, mutated only from the
/// main thread (the Settings theme picker); reads from other contexts are benign.
@Observable
final class ThemeManager: @unchecked Sendable {
    static let shared = ThemeManager()

    var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: SettingsKeys.appTheme)
        }
    }

    var palette: ThemePalette { theme.palette }

    private init() {
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.appTheme) ?? "Midnight") ?? .midnight
    }
}

// MARK: - Dynamic Color Palette (reads active theme)

extension Color {
    private static var activePalette: ThemePalette { ThemeManager.shared.palette }

    // Backgrounds
    static var backgroundPrimary: Color { activePalette.backgroundPrimary }
    static var backgroundSecondary: Color { activePalette.backgroundSecondary }
    static var cardSurface: Color { activePalette.cardSurface }

    // Accent colors
    static var feltGreen: Color { activePalette.feltGreen }
    static var goldAccent: Color { activePalette.goldAccent }
    static var chipRed: Color { activePalette.chipRed }
    static var chipBlue: Color { activePalette.chipBlue }

    // Chat bubbles
    static var userBubble: Color { activePalette.userBubble }
    static var aiBubble: Color { activePalette.aiBubble }

    // Text
    static var textPrimary: Color { activePalette.textPrimary }
    static var textSecondary: Color { activePalette.textSecondary }

    // M-Zone colors
    static var mZoneGreen: Color { activePalette.mZoneGreen }
    static var mZoneYellow: Color { activePalette.mZoneYellow }
    static var mZoneOrange: Color { activePalette.mZoneOrange }
    static var mZoneRed: Color { activePalette.mZoneRed }

    // Borders
    static var borderSubtle: Color { activePalette.borderSubtle }
}

// MARK: - Poker Typography

struct PokerTypography {
    /// System font whose size scales with Dynamic Type, relative to the given text style.
    private static func scaledSystem(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design = .default,
        relativeTo textStyle: UIFont.TextStyle
    ) -> Font {
        Font.system(
            size: UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size),
            weight: weight,
            design: design
        )
    }

    static var heroStat: Font { scaledSystem(size: 42, weight: .bold, design: .rounded, relativeTo: .largeTitle) }
    static var statValue: Font { scaledSystem(size: 18, weight: .semibold, design: .monospaced, relativeTo: .body) }
    static var chatBody: Font { scaledSystem(size: 15, weight: .regular, relativeTo: .subheadline) }
    static var chatCaption: Font { scaledSystem(size: 11, weight: .regular, relativeTo: .caption2) }
    static var blindLevel: Font { scaledSystem(size: 14, weight: .bold, design: .monospaced, relativeTo: .footnote) }
    static var sectionHeader: Font { scaledSystem(size: 13, weight: .bold, relativeTo: .footnote) }
    static var chipLabel: Font { scaledSystem(size: 12, weight: .medium, relativeTo: .caption1) }

    // Share card typography — rendered into fixed-size export canvases
    // (share images/video frames), so these intentionally do NOT scale
    // with Dynamic Type to avoid overflowing the canvas.
    static let shareHero = Font.system(size: 36, weight: .bold, design: .rounded)
    static let shareValue = Font.system(size: 16, weight: .semibold, design: .monospaced)
    static let shareLabel = Font.system(size: 10, weight: .medium)
}

// MARK: - View Modifiers

struct PokerCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.borderSubtle, lineWidth: 0.5)
            )
    }
}

struct ChatBubbleStyle: ViewModifier {
    let isUser: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Color.userBubble : Color.aiBubble)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct QuickChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(PokerTypography.chipLabel)
            .foregroundColor(.goldAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.goldAccent.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
    }
}

struct PokerButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundColor(.backgroundPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isEnabled ? Color.goldAccent : Color.goldAccent.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - View Extensions

extension View {
    func pokerCard() -> some View {
        modifier(PokerCardStyle())
    }

    func chatBubble(isUser: Bool) -> some View {
        modifier(ChatBubbleStyle(isUser: isUser))
    }

    func quickChip() -> some View {
        modifier(QuickChipStyle())
    }
}

// MARK: - Haptic Feedback

@MainActor
struct HapticFeedback {
    private static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: SettingsKeys.hapticFeedback) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: SettingsKeys.hapticFeedback)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }

    static func success() {
        notification(.success)
    }

    static func error() {
        notification(.error)
    }
}
