import SwiftUI

struct GameTypePickerView: View {
    @Binding var selectedRawValue: String
    @State private var showAddCustom = false
    @State private var showManageSheet = false
    @State private var customAbbrev = ""
    @State private var customLabel = ""

    private var allOptions: [(rawValue: String, label: String)] {
        GameTypeStore.shared.allOptions
    }

    var body: some View {
        Picker("Game Type", selection: $selectedRawValue) {
            ForEach(allOptions, id: \.rawValue) { option in
                Text(option.label).tag(option.rawValue)
            }
        }
        .tint(.goldAccent)

        Button {
            showAddCustom = true
        } label: {
            HStack {
                Image(systemName: "plus.circle")
                Text("Add Custom Game Type")
            }
            .font(PokerTypography.chatBody)
            .foregroundColor(.goldAccent)
        }
        .alert("Add Custom Game Type", isPresented: $showAddCustom) {
            TextField("Abbreviation (e.g. PLO5)", text: $customAbbrev)
            TextField("Full Name (e.g. 5-Card PLO)", text: $customLabel)
            Button("Add") {
                let abbrev = customAbbrev.trimmingCharacters(in: .whitespaces)
                let label = customLabel.trimmingCharacters(in: .whitespaces)
                if !abbrev.isEmpty && !label.isEmpty {
                    GameTypeStore.shared.add(rawValue: abbrev, label: label)
                    selectedRawValue = abbrev
                }
                customAbbrev = ""
                customLabel = ""
            }
            Button("Cancel", role: .cancel) {
                customAbbrev = ""
                customLabel = ""
            }
        } message: {
            Text("Enter an abbreviation and full name for the game type.")
        }

        if !GameTypeStore.shared.customTypes.isEmpty {
            Button {
                showManageSheet = true
            } label: {
                HStack {
                    Image(systemName: "pencil.circle")
                    Text("Manage Game Types")
                }
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
            }
            .sheet(isPresented: $showManageSheet) {
                ManageGameTypesSheet(selectedRawValue: $selectedRawValue)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Manage Game Types Sheet

struct ManageGameTypesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRawValue: String
    @State private var customTypes: [GameTypeStore.CustomType] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(GameType.allCases, id: \.self) { type in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.label)
                                    .font(.body)
                                    .foregroundColor(.textPrimary)
                                Text(type.rawValue)
                                    .font(PokerTypography.chatCaption)
                                    .foregroundColor(.textSecondary)
                            }
                            Spacer()
                            Text("Built-in")
                                .font(PokerTypography.chatCaption)
                                .foregroundColor(.textSecondary)
                        }
                    }
                } header: {
                    Text("BUILT-IN")
                        .font(PokerTypography.sectionHeader)
                        .foregroundColor(.textSecondary)
                }
                .listRowBackground(Color.cardSurface)

                if !customTypes.isEmpty {
                    Section {
                        ForEach(customTypes) { type in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(type.label)
                                        .font(.body)
                                        .foregroundColor(.textPrimary)
                                    Text(type.rawValue)
                                        .font(PokerTypography.chatCaption)
                                        .foregroundColor(.textSecondary)
                                }
                                Spacer()
                            }
                        }
                        .onDelete(perform: deleteCustomTypes)
                    } header: {
                        Text("CUSTOM")
                            .font(PokerTypography.sectionHeader)
                            .foregroundColor(.textSecondary)
                    }
                    .listRowBackground(Color.cardSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle("Game Types")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.goldAccent)
                }
            }
            .onAppear {
                customTypes = GameTypeStore.shared.customTypes
            }
        }
    }

    private func deleteCustomTypes(at offsets: IndexSet) {
        for index in offsets {
            let type = customTypes[index]
            if selectedRawValue == type.rawValue {
                selectedRawValue = GameType.nlh.rawValue
            }
            GameTypeStore.shared.remove(rawValue: type.rawValue)
        }
        customTypes = GameTypeStore.shared.customTypes
    }
}
