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
            (a, r, g, b) = (255, 1, 1, 1)
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

// MARK: - Poker Color Palette

extension Color {
    // Backgrounds
    static let backgroundPrimary = Color(hex: "0A0E14")
    static let backgroundSecondary = Color(hex: "131820")
    static let cardSurface = Color(hex: "1A2030")

    // Accent colors
    static let feltGreen = Color(hex: "1B5E20")
    static let goldAccent = Color(hex: "FFD54F")
    static let chipRed = Color(hex: "E53935")
    static let chipBlue = Color(hex: "1E88E5")

    // Chat bubbles
    static let userBubble = Color(hex: "1B5E20")
    static let aiBubble = Color(hex: "2A2D35")

    // Text
    static let textPrimary = Color(hex: "E8EAED")
    static let textSecondary = Color(hex: "9AA0A6")

    // M-Zone colors
    static let mZoneGreen = Color(hex: "4CAF50")
    static let mZoneYellow = Color(hex: "FFC107")
    static let mZoneOrange = Color(hex: "FF9800")
    static let mZoneRed = Color(hex: "F44336")

    // Borders
    static let borderSubtle = Color.white.opacity(0.08)
}

// MARK: - Poker Typography

struct PokerTypography {
    static let heroStat = Font.system(size: 42, weight: .bold, design: .rounded)
    static let statValue = Font.system(size: 18, weight: .semibold, design: .monospaced)
    static let chatBody = Font.system(size: 15, weight: .regular)
    static let chatCaption = Font.system(size: 11, weight: .regular)
    static let blindLevel = Font.system(size: 14, weight: .bold, design: .monospaced)
    static let sectionHeader = Font.system(size: 13, weight: .bold)
    static let chipLabel = Font.system(size: 12, weight: .medium)
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
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
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
