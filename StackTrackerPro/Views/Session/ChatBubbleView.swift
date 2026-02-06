import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)
                    .chatBubble(isUser: message.isUser)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 4)
            }

            if message.isAI { Spacer(minLength: 60) }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ChatBubbleView(message: {
            let m = ChatMessage(sender: .user, text: "Level 7, 18k, 310 left, got a bounty")
            return m
        }())
        ChatBubbleView(message: {
            let m = ChatMessage(sender: .ai, text: "Stack: 18k\n45 BB  |  M-ratio: 12.0 (Yellow Zone)\nGetting shorter. Start widening your opening range.")
            return m
        }())
    }
    .padding()
    .background(Color.backgroundPrimary)
}
