import SwiftUI
import SwiftData

struct CashSessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CashSessionManager.self) private var cashSessionManager
    @Query(filter: #Predicate<CashSession> { $0.statusRaw != "completed" },
           sort: \CashSession.startTime, order: .reverse)
    private var sessions: [CashSession]

    @State private var showingSetup = false

    var body: some View {
        ZStack {
            Color.backgroundPrimary.ignoresSafeArea()

            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSetup = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            CashSessionSetupView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Cash Sessions")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Tap + to start tracking a cash game")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showingSetup = true
            } label: {
                Text("New Cash Session")
            }
            .buttonStyle(PokerButtonStyle(isEnabled: true))
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .padding()
    }

    private var sessionList: some View {
        List {
            ForEach(sessions, id: \.persistentModelID) { session in
                NavigationLink {
                    CashActiveSessionView(session: session)
                } label: {
                    sessionRow(session)
                }
                .listRowBackground(Color.cardSurface)
            }
            .onDelete(perform: deleteSessions)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func sessionRow(_ session: CashSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                if let venue = session.venueName {
                    Text(venue)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }

                Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: session.status.icon)
                    .font(.caption2)
                Text(session.status.label)
                    .font(PokerTypography.chipLabel)
            }
            .foregroundColor(session.status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(session.status.color.opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            if cashSessionManager.activeSession?.persistentModelID == session.persistentModelID {
                cashSessionManager.activeSession = nil
            }
            modelContext.delete(session)
        }
    }
}
