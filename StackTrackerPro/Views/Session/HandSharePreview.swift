import SwiftUI

/// In-app preview of a hand's text history with colored suits; shares the
/// PLAIN text (color cannot travel in shared plain text — by design).
struct HandSharePreview: View {
    let hand: Hand
    @Environment(\.dismiss) private var dismiss

    private var plainText: String { HandHistoryFormatter.text(for: hand) }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(colorized(plainText))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Share Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: plainText) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Red for ♥/♦ glyph plus its preceding rank character; default color otherwise.
    static func colorized(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        var index = result.startIndex
        var previous: AttributedString.Index?
        while index < result.endIndex {
            let ch = result.characters[index]
            if ch == "♥" || ch == "♦" {
                let next = result.index(afterCharacter: index)
                result[index..<next].foregroundColor = .red
                if let previous {
                    result[previous..<index].foregroundColor = .red
                }
            }
            previous = index
            index = result.index(afterCharacter: index)
        }
        return result
    }

    private func colorized(_ text: String) -> AttributedString {
        Self.colorized(text)
    }
}
