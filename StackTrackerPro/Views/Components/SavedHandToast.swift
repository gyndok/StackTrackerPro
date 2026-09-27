import SwiftUI
import SwiftData

/// "Hand saved" confirmation with a Share affordance (spec §6). Replaces the
/// post-save dialog: the capture screen dismisses at once and the presenter
/// shows this for four seconds.
struct SavedHandToast: View {
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.mZoneGreen)
            Text("Hand saved").font(PokerTypography.chipLabel).foregroundColor(.textPrimary)
            Spacer()
            Button("Share", action: onShare)
                .font(PokerTypography.chipLabel.weight(.semibold))
                .foregroundColor(.goldAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

private struct SavedHandToastModifier: ViewModifier {
    @Binding var hand: Hand?
    let onShare: (Hand) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let shown = hand {
                    SavedHandToast {
                        onShare(shown)
                        hand = nil
                    }
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: hand?.persistentModelID)
            .task(id: hand?.persistentModelID) {
                guard hand != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                hand = nil
            }
    }
}

extension View {
    /// Shows `SavedHandToast` while `hand` is non-nil, auto-clearing after 4 s.
    func savedHandToast(hand: Binding<Hand?>, onShare: @escaping (Hand) -> Void) -> some View {
        modifier(SavedHandToastModifier(hand: hand, onShare: onShare))
    }
}
