import SwiftUI
import SwiftData

/// Searchable library of saved blind structures. Presented as a sheet.
/// When `onSelect` is provided, tapping a template returns it to the caller
/// and dismisses; otherwise the view is browse/manage only.
struct StructureLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BlindStructureTemplate.createdDate, order: .reverse)
    private var templates: [BlindStructureTemplate]

    @State private var searchText = ""

    var onSelect: ((BlindStructureTemplate) -> Void)?

    private var filteredTemplates: [BlindStructureTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return templates }
        return templates.filter { template in
            template.name.localizedCaseInsensitiveContains(query) ||
            (template.venueName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                if templates.isEmpty {
                    emptyState
                } else if filteredTemplates.isEmpty {
                    noMatchesState
                } else {
                    templateList
                }
            }
            .navigationTitle("Structure Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search by name or venue")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(onSelect != nil ? "Cancel" : "Done") {
                        dismiss()
                    }
                    .foregroundColor(.goldAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var templateList: some View {
        List {
            ForEach(filteredTemplates) { template in
                Button {
                    if let onSelect {
                        onSelect(template)
                        dismiss()
                    }
                } label: {
                    templateRow(template)
                }
                .disabled(onSelect == nil)
            }
            .onDelete(perform: deleteTemplates)
            .listRowBackground(Color.cardSurface)
        }
        .scrollContentBackground(.hidden)
    }

    private func templateRow(_ template: BlindStructureTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name)
                .font(PokerTypography.statValue)
                .foregroundColor(.textPrimary)

            HStack(spacing: 6) {
                if let venue = template.venueName, !venue.isEmpty {
                    Text(venue)
                    Text("·")
                }
                Text("\(template.playingLevelCount) levels")
                if template.startingChips > 0 {
                    Text("·")
                    Text("\(template.startingChips.formatted()) chips")
                }
            }
            .font(PokerTypography.chipLabel)
            .foregroundColor(.textSecondary)

            Text(template.createdDate.formatted(date: .abbreviated, time: .omitted))
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundColor(.textSecondary)
                .accessibilityHidden(true)
            Text("No Saved Structures")
                .font(PokerTypography.statValue)
                .foregroundColor(.textPrimary)
            Text("Save a structure from the blind editor and it will appear here for reuse.")
                .font(PokerTypography.chipLabel)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.textSecondary)
                .accessibilityHidden(true)
            Text("No matches for \"\(searchText)\"")
                .font(PokerTypography.chipLabel)
                .foregroundColor(.textSecondary)
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredTemplates[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    StructureLibraryView()
        .modelContainer(for: BlindStructureTemplate.self, inMemory: true)
}
