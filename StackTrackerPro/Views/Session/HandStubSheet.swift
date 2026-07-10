import SwiftUI

/// The 5-second capture sheet: hole cards (picker or typed shorthand),
/// optional one-tap result chips, Save. All context auto-fills at save time.
struct HandStubSheet: View {
    /// Optional escape hatch to the voice capture flow. Non-nil renders a
    /// "Talk instead" button under the quick chips; tapping it hands off to
    /// the caller (which starts dictation) then dismisses this sheet.
    let onDictate: (() -> Void)?
    let onSave: (String, QuickResult?, QuickVillain?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pickedCards: [PlayingCard] = []
    @State private var shorthand = ""
    @State private var quickResult: QuickResult?
    @State private var quickVillain: QuickVillain?
    @FocusState private var shorthandFocused: Bool

    private var storedCards: String? {
        if pickedCards.count == 2 { return PlayingCard.joinList(pickedCards) }
        return HoleCardShorthand.normalize(shorthand)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Picked cards display
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { i in
                        Text(i < pickedCards.count ? pickedCards[i].display : "–")
                            .font(.title2.bold())
                            .frame(width: 56, height: 72)
                            .background(Color.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !pickedCards.isEmpty {
                        Button { pickedCards.removeAll() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                }

                CardPickerGrid(dealt: Set(pickedCards)) { card in
                    guard pickedCards.count < 2 else { return }
                    pickedCards.append(card)
                }

                TextField("or type: KQs, AhKd, 99", text: $shorthand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .focused($shorthandFocused)
                    // Keyboard Done: lets the user put the keyboard away to
                    // reach the result chips below (F18).
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { shorthandFocused = false }
                        }
                    }

                // Optional one-tap chips
                HStack {
                    ForEach(QuickResult.allCases, id: \.self) { r in
                        Button(r.rawValue) { quickResult = (quickResult == r ? nil : r) }
                            .buttonStyle(.bordered)
                            .tint(quickResult == r ? .goldAccent : .secondary)
                    }
                }
                HStack {
                    ForEach(QuickVillain.allCases, id: \.self) { v in
                        Button(v.rawValue) { quickVillain = (quickVillain == v ? nil : v) }
                            .buttonStyle(.bordered)
                            .tint(quickVillain == v ? .goldAccent : .secondary)
                    }
                }

                if let onDictate {
                    Button {
                        onDictate()
                        dismiss()
                    } label: {
                        Label("Talk instead", systemImage: "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.goldAccent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Log Hand Stub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(storedCards ?? "", quickResult, quickVillain)
                        dismiss()
                    }
                    .disabled(storedCards == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    HandStubSheet(onDictate: nil) { cards, result, villain in
        print(cards, result ?? "", villain ?? "")
    }
}
