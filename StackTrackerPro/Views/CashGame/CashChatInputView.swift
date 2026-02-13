import SwiftUI

struct CashChatInputView: View {
    @Environment(CashSessionManager.self) private var cashSessionManager

    @State private var stackText = ""
    @FocusState private var isFocused: Bool

    var onAddOn: () -> Void
    var onCashOut: () -> Void
    var onHandNote: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        onAddOn()
                        HapticFeedback.impact(.light)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.caption)
                            Text("Add-on")
                        }
                        .quickChip()
                    }

                    Button {
                        onCashOut()
                        HapticFeedback.impact(.light)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "banknote")
                                .font(.caption)
                            Text("Cash Out")
                        }
                        .quickChip()
                    }

                    Button {
                        onHandNote()
                        HapticFeedback.impact(.light)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "note.text")
                                .font(.caption)
                            Text("Hand Note")
                        }
                        .quickChip()
                    }
                }
                .padding(.horizontal, 16)
            }

            // Text input
            HStack(spacing: 10) {
                TextField("Update your stack ($)...", text: $stackText)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.borderSubtle, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit { sendStack() }

                Button {
                    sendStack()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(canSend ? .goldAccent : .goldAccent.opacity(0.3))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color.backgroundSecondary)
    }

    private var canSend: Bool {
        guard let amount = Int(stackText.trimmingCharacters(in: .whitespacesAndNewlines)),
              amount > 0 else { return false }
        return true
    }

    private func sendStack() {
        guard let amount = Int(stackText.trimmingCharacters(in: .whitespacesAndNewlines)),
              amount > 0 else { return }
        cashSessionManager.updateStack(dollarAmount: amount)
        HapticFeedback.impact(.light)
        stackText = ""
        isFocused = false
    }
}

#Preview {
    VStack {
        Spacer()
        CashChatInputView(
            onAddOn: {},
            onCashOut: {},
            onHandNote: {}
        )
    }
    .background(Color.backgroundPrimary)
    .environment(CashSessionManager())
}
