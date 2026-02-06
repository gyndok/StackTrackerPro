import SwiftUI
import SwiftData
import PhotosUI

struct BlindStructureEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var tournament: Tournament

    var scannedLevels: [ScannedBlindLevel] = []

    @State private var showingTemplates = false

    // Scanner state
    @State private var showingPhotoSource = false
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var showingScanError = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    var sortedLevels: [BlindLevel] {
        tournament.blindLevels.sorted { $0.levelNumber < $1.levelNumber }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                List {
                    headerRow

                    ForEach(sortedLevels, id: \.persistentModelID) { level in
                        levelRow(level)
                    }
                    .onDelete(perform: deleteLevels)

                    addButtons
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .navigationTitle("Blind Structure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.goldAccent)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingTemplates = true
                        } label: {
                            Label("Load Template", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            showingPhotoSource = true
                        } label: {
                            Label("Scan from Screenshot", systemImage: "camera.viewfinder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.goldAccent)
                    }
                }
            }
            .confirmationDialog("Load Template", isPresented: $showingTemplates) {
                Button("Standard Casino (30 min)") { loadTemplate(.standard) }
                Button("Turbo (15 min)") { loadTemplate(.turbo) }
                Button("Deep Stack (40 min)") { loadTemplate(.deepStack) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Scan Source", isPresented: $showingPhotoSource) {
                Button("Photo Library") { showingPhotoPicker = true }
                Button("Camera") { showingCamera = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        scanImage(uiImage)
                    }
                }
                selectedPhotoItem = nil
            }
            .sheet(isPresented: $showingCamera) {
                CameraView { image in
                    scanImage(image)
                }
            }
            .alert("Scan Error", isPresented: $showingScanError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanError ?? "Unknown error")
            }
            .overlay {
                if isScanning {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    ProgressView("Scanning...")
                        .tint(.goldAccent)
                        .foregroundColor(.textPrimary)
                        .padding()
                        .background(Color.cardSurface.cornerRadius(12))
                }
            }
            .onAppear {
                if !scannedLevels.isEmpty {
                    loadScannedLevels(scannedLevels)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Lvl")
                .frame(width: 32, alignment: .leading)
            Text("SB")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("BB")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Ante")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Min")
                .frame(width: 40, alignment: .trailing)
        }
        .font(PokerTypography.sectionHeader)
        .foregroundColor(.goldAccent)
        .listRowBackground(Color.backgroundSecondary)
    }

    private func levelRow(_ level: BlindLevel) -> some View {
        Group {
            if level.isBreak {
                HStack {
                    Text("—")
                        .frame(width: 32, alignment: .leading)
                    Text(level.breakLabel ?? "Break")
                        .foregroundColor(.mZoneYellow)
                    Spacer()
                    Text("\(level.durationMinutes)")
                        .frame(width: 40, alignment: .trailing)
                }
                .font(PokerTypography.blindLevel)
                .foregroundColor(.textSecondary)
            } else {
                HStack {
                    Text("\(level.levelNumber)")
                        .frame(width: 32, alignment: .leading)
                        .foregroundColor(.textSecondary)
                    EditableNumber(value: Binding(
                        get: { level.smallBlind },
                        set: { level.smallBlind = $0 }
                    ))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    EditableNumber(value: Binding(
                        get: { level.bigBlind },
                        set: { level.bigBlind = $0 }
                    ))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    EditableNumber(value: Binding(
                        get: { level.ante },
                        set: { level.ante = $0 }
                    ))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    EditableNumber(value: Binding(
                        get: { level.durationMinutes },
                        set: { level.durationMinutes = $0 }
                    ))
                    .frame(width: 40, alignment: .trailing)
                }
                .font(PokerTypography.blindLevel)
                .foregroundColor(.textPrimary)
            }
        }
        .listRowBackground(Color.cardSurface)
    }

    private var addButtons: some View {
        Section {
            Button {
                addLevel()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Level")
                }
                .foregroundColor(.goldAccent)
            }

            Button {
                addBreak()
            } label: {
                HStack {
                    Image(systemName: "cup.and.saucer.fill")
                    Text("Add Break")
                }
                .foregroundColor(.mZoneYellow)
            }
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Actions

    private func addLevel() {
        let lastLevel = sortedLevels.last(where: { !$0.isBreak })
        let nextNumber = (sortedLevels.last?.levelNumber ?? 0) + 1
        let sb = (lastLevel?.smallBlind ?? 50) * 2
        let bb = (lastLevel?.bigBlind ?? 100) * 2
        let ante = lastLevel?.ante ?? 0 > 0 ? (lastLevel?.ante ?? 0) * 2 : 0
        let duration = lastLevel?.durationMinutes ?? 30

        let level = BlindLevel(
            levelNumber: nextNumber,
            smallBlind: sb,
            bigBlind: bb,
            ante: ante,
            durationMinutes: duration
        )
        tournament.blindLevels.append(level)
    }

    private func addBreak() {
        let nextNumber = (sortedLevels.last?.levelNumber ?? 0) + 1
        let breakLevel = BlindLevel(
            levelNumber: nextNumber,
            smallBlind: 0,
            bigBlind: 0,
            ante: 0,
            durationMinutes: 15,
            isBreak: true,
            breakLabel: "Break"
        )
        tournament.blindLevels.append(breakLevel)
    }

    private func deleteLevels(at offsets: IndexSet) {
        let sorted = sortedLevels
        for index in offsets {
            let level = sorted[index]
            tournament.blindLevels.removeAll { $0.persistentModelID == level.persistentModelID }
        }
    }

    private func loadTemplate(_ template: BlindTemplate) {
        // Clear existing
        tournament.blindLevels.removeAll()

        // Load template levels
        for level in template.levels {
            tournament.blindLevels.append(level)
        }

        HapticFeedback.success()
    }

    // MARK: - Scanning

    private func scanImage(_ image: UIImage) {
        isScanning = true
        Task {
            do {
                let result = try await PokerAtlasScanner.shared.scan(image: image)
                await MainActor.run {
                    if !result.blindLevels.isEmpty {
                        loadScannedLevels(result.blindLevels)
                        HapticFeedback.success()
                    } else {
                        scanError = "No blind levels found in the image."
                        showingScanError = true
                        HapticFeedback.error()
                    }
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    showingScanError = true
                    isScanning = false
                    HapticFeedback.error()
                }
            }
        }
    }

    private func loadScannedLevels(_ levels: [ScannedBlindLevel]) {
        tournament.blindLevels.removeAll()

        for scanned in levels {
            let level = BlindLevel(
                levelNumber: scanned.levelNumber,
                smallBlind: scanned.smallBlind,
                bigBlind: scanned.bigBlind,
                ante: scanned.ante,
                durationMinutes: scanned.durationMinutes,
                isBreak: scanned.isBreak,
                breakLabel: scanned.breakLabel
            )
            tournament.blindLevels.append(level)
        }

        HapticFeedback.success()
    }
}

// MARK: - Editable Number Field

struct EditableNumber: View {
    @Binding var value: Int
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .font(PokerTypography.blindLevel)
            .foregroundColor(.textPrimary)
            .focused($isFocused)
            .onAppear { text = "\(value)" }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    value = Int(text) ?? value
                }
            }
    }
}

// MARK: - Blind Templates

enum BlindTemplate {
    case standard
    case turbo
    case deepStack

    var levels: [BlindLevel] {
        switch self {
        case .standard:
            return standardCasino()
        case .turbo:
            return turbo()
        case .deepStack:
            return deepStack()
        }
    }

    private func standardCasino() -> [BlindLevel] {
        let structure: [(sb: Int, bb: Int, ante: Int)] = [
            (100, 200, 0), (200, 400, 0), (300, 600, 100),
            (400, 800, 100), (500, 1000, 200), (600, 1200, 200),
            (800, 1600, 300), (1000, 2000, 300), (1500, 3000, 500),
            (2000, 4000, 500), (2500, 5000, 500), (3000, 6000, 1000),
            (4000, 8000, 1000), (5000, 10000, 1000), (6000, 12000, 2000),
            (8000, 16000, 2000), (10000, 20000, 3000), (15000, 30000, 5000),
        ]
        return structure.enumerated().map { index, s in
            BlindLevel(levelNumber: index + 1, smallBlind: s.sb, bigBlind: s.bb,
                       ante: s.ante, durationMinutes: 30)
        }
    }

    private func turbo() -> [BlindLevel] {
        let structure: [(sb: Int, bb: Int, ante: Int)] = [
            (100, 200, 0), (200, 400, 50), (300, 600, 100),
            (500, 1000, 200), (800, 1600, 300), (1000, 2000, 400),
            (1500, 3000, 500), (2000, 4000, 500), (3000, 6000, 1000),
            (5000, 10000, 1000), (8000, 16000, 2000), (10000, 20000, 3000),
        ]
        return structure.enumerated().map { index, s in
            BlindLevel(levelNumber: index + 1, smallBlind: s.sb, bigBlind: s.bb,
                       ante: s.ante, durationMinutes: 15)
        }
    }

    private func deepStack() -> [BlindLevel] {
        let structure: [(sb: Int, bb: Int, ante: Int)] = [
            (50, 100, 0), (100, 200, 0), (100, 200, 25),
            (150, 300, 50), (200, 400, 50), (300, 600, 100),
            (400, 800, 100), (500, 1000, 200), (600, 1200, 200),
            (800, 1600, 300), (1000, 2000, 300), (1200, 2400, 400),
            (1500, 3000, 500), (2000, 4000, 500), (2500, 5000, 500),
            (3000, 6000, 1000), (4000, 8000, 1000), (5000, 10000, 1000),
            (6000, 12000, 2000), (8000, 16000, 2000), (10000, 20000, 3000),
        ]
        return structure.enumerated().map { index, s in
            BlindLevel(levelNumber: index + 1, smallBlind: s.sb, bigBlind: s.bb,
                       ante: s.ante, durationMinutes: 40)
        }
    }
}

#Preview {
    BlindStructureEditorView(tournament: Tournament(name: "Preview"))
        .modelContainer(for: Tournament.self, inMemory: true)
}
