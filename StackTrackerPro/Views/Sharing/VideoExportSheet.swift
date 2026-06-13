import SwiftUI
import AVKit

struct VideoExportSheet: View {
    let tournament: Tournament
    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var videoURL: URL?
    @State private var error: String?
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let error {
                    errorView(error)
                } else if let url = videoURL {
                    completedView(url)
                } else {
                    generatingView
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.backgroundPrimary)
            .navigationTitle("Recap Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        generationTask?.cancel()
                        dismiss()
                    }
                    .foregroundColor(.goldAccent)
                }
            }
            .onAppear {
                startGeneration()
            }
            // Note: the exported file is intentionally NOT deleted on
            // disappear — a ShareLink save may still be in flight.
            // VideoComposer writes into a dedicated temp subdirectory and
            // cleans stale exports on the next export.
        }
    }

    // MARK: - Generating State

    private var generatingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundColor(.goldAccent)
                .accessibilityHidden(true)

            Text("Creating your recap...")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.textPrimary)

            ProgressView(value: progress)
                .tint(.goldAccent)
                .padding(.horizontal, 48)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.textSecondary)

            Button("Cancel") {
                generationTask?.cancel()
                dismiss()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.textSecondary)
        }
    }

    // MARK: - Completed State

    private func completedView(_ url: URL) -> some View {
        VStack(spacing: 16) {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(width: 200, height: 355)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

            ShareLink(item: url) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share Video")
                }
                .font(.headline.weight(.semibold))
                .foregroundColor(.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.goldAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Error State

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.goldAccent)
                .accessibilityHidden(true)

            Text("Something went wrong")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.textPrimary)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Try Again") {
                error = nil
                progress = 0
                startGeneration()
            }
            .font(.headline.weight(.semibold))
            .foregroundColor(.backgroundPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.goldAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Generation

    private func startGeneration() {
        generationTask = Task {
            do {
                let composer = VideoComposer()
                let url = try await composer.generate(tournament: tournament) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }
                videoURL = url
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
