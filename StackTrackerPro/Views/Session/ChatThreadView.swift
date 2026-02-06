import SwiftUI

struct ChatThreadView: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages, id: \.persistentModelID) { message in
                            ChatBubbleView(message: message)
                                .id(message.persistentModelID)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.persistentModelID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))

            Text("Start chatting to track your tournament")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                hintRow("\"I have 32k\"", description: "Update your stack")
                hintRow("\"Level 7, 500/1000\"", description: "Update blinds")
                hintRow("\"310 left\"", description: "Update field")
                hintRow("\"Got a bounty\"", description: "Record a bounty")
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    private func hintRow(_ example: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(example)
                .font(PokerTypography.blindLevel)
                .foregroundColor(.goldAccent)
            Text("—")
                .foregroundColor(.textSecondary)
            Text(description)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
        }
    }
}

#Preview {
    ChatThreadView(messages: [])
        .background(Color.backgroundPrimary)
}
