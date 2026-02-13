import SwiftUI
import SwiftData

struct CashSessionSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CashSessionManager.self) private var cashSessionManager

    @AppStorage(SettingsKeys.defaultGameType) private var savedGameType = GameType.nlh.rawValue

    @State private var stakes = ""
    @State private var customStakes = ""
    @State private var gameTypeRaw: String = GameType.nlh.rawValue
    @State private var venueName = ""
    @State private var buyIn = ""

    private let stakesPresets = ["1/2", "1/3", "2/5", "5/10"]

    private var isValid: Bool {
        let effectiveStakes = stakes.isEmpty ? customStakes.trimmingCharacters(in: .whitespaces) : stakes
        return !effectiveStakes.isEmpty && (Int(buyIn) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                Form {
                    gameInfoSection
                    venueSection
                    buyInSection
                    startButtonSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Cash Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .onAppear {
                gameTypeRaw = savedGameType
            }
        }
    }

    // MARK: - Sections

    private var gameInfoSection: some View {
        Section {
            // Stakes presets
            VStack(alignment: .leading, spacing: 8) {
                Text("Stakes")
                    .foregroundColor(.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stakesPresets, id: \.self) { preset in
                            Button {
                                stakes = preset
                                customStakes = ""
                                HapticFeedback.impact(.light)
                            } label: {
                                Text(preset)
                                    .font(PokerTypography.chipLabel)
                                    .foregroundColor(stakes == preset ? .backgroundPrimary : .goldAccent)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(stakes == preset ? Color.goldAccent : Color.goldAccent.opacity(0.15))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }

            // Custom stakes
            HStack {
                Text("Custom")
                    .foregroundColor(.textSecondary)
                Spacer()
                TextField("e.g. 2/3/5", text: $customStakes)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: customStakes) { _, newValue in
                        if !newValue.isEmpty {
                            stakes = ""
                        }
                    }
            }

            // Game type picker
            GameTypePickerView(selectedRawValue: $gameTypeRaw)
        } header: {
            Text("GAME INFO")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var venueSection: some View {
        Section {
            TextField("Venue Name", text: $venueName)
                .foregroundColor(.textPrimary)
        } header: {
            Text("VENUE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var buyInSection: some View {
        Section {
            HStack {
                Text("$")
                    .foregroundColor(.textSecondary)
                TextField("Buy-in amount", text: $buyIn)
                    .keyboardType(.numberPad)
                    .foregroundColor(.textPrimary)
            }
        } header: {
            Text("BUY-IN")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var startButtonSection: some View {
        Section {
            Button {
                startSession()
            } label: {
                Text("Start Session")
            }
            .buttonStyle(PokerButtonStyle(isEnabled: isValid))
            .disabled(!isValid)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    // MARK: - Actions

    private func startSession() {
        let effectiveStakes = stakes.isEmpty ? customStakes.trimmingCharacters(in: .whitespaces) : stakes
        guard !effectiveStakes.isEmpty, let buyInAmount = Int(buyIn), buyInAmount > 0 else { return }

        let session = CashSession(
            stakes: effectiveStakes,
            gameTypeRaw: gameTypeRaw,
            buyInTotal: buyInAmount,
            venueName: venueName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : venueName.trimmingCharacters(in: .whitespaces)
        )

        modelContext.insert(session)
        cashSessionManager.setContext(modelContext)
        cashSessionManager.startSession(session)

        HapticFeedback.success()
        dismiss()
    }
}

#Preview {
    CashSessionSetupView()
        .modelContainer(for: CashSession.self, inMemory: true)
        .environment(CashSessionManager())
}
