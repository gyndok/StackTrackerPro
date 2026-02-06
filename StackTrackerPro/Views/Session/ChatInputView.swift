import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    let isProcessing: Bool
    let onSend: () -> Void
    let onQuickAction: (QuickAction) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuickAction.allCases, id: \.self) { action in
                        Button {
                            onQuickAction(action)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.caption)
                                Text(action.rawValue)
                            }
                            .quickChip()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // Text input
            HStack(spacing: 10) {
                TextField("Update your stack...", text: $text)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.borderSubtle, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit { sendIfReady() }

                Button {
                    sendIfReady()
                } label: {
                    if isProcessing {
                        ProgressView()
                            .tint(.backgroundPrimary)
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(canSend ? .goldAccent : .goldAccent.opacity(0.3))
                    }
                }
                .disabled(!canSend || isProcessing)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color.backgroundSecondary)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendIfReady() {
        guard canSend else { return }
        onSend()
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputView(
            text: .constant("18k"),
            isProcessing: false,
            onSend: {},
            onQuickAction: { _ in }
        )
    }
    .background(Color.backgroundPrimary)
}
