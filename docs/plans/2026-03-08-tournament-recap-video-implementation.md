# Tournament Recap Video Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Generate a ~10-15 second silent vertical video from a tournament's stack graph and chip photos, shareable to social media.

**Architecture:** Frame-by-frame rendering using SwiftUI `ImageRenderer` to produce UIImages, converted to CVPixelBuffers, and written to MP4 via `AVAssetWriter`. A progress parameter (0.0→1.0) drives a SwiftUI view through three acts: title card, animated graph with inline photos, and recap card.

**Tech Stack:** SwiftUI, AVFoundation (AVAssetWriter), CoreVideo (CVPixelBuffer), Swift Charts, SwiftData

---

### Task 1: VideoComposer — Pixel Buffer & AVAssetWriter Core

Create the core video generation engine that converts UIImages to pixel buffers and writes them as an MP4 file.

**Files:**
- Create: `StackTrackerPro/Managers/VideoComposer.swift`

**Step 1: Create VideoComposer with pixel buffer conversion**

```swift
import AVFoundation
import CoreVideo
import SwiftUI
import UIKit

enum VideoComposerError: LocalizedError {
    case cannotCreateWriter
    case cannotCreatePixelBuffer
    case renderingFailed
    case writingFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateWriter: return "Could not create video writer."
        case .cannotCreatePixelBuffer: return "Could not create pixel buffer."
        case .renderingFailed: return "Failed to render video frame."
        case .writingFailed: return "Failed to write video file."
        }
    }
}

@MainActor
final class VideoComposer {

    struct Config {
        let width: Int = 1080
        let height: Int = 1920
        let fps: Int = 30

        var size: CGSize { CGSize(width: width, height: height) }
        /// SwiftUI proposed size at @3x
        var proposedSize: CGSize { CGSize(width: CGFloat(width) / 3, height: CGFloat(height) / 3) }
        var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(fps)) }
    }

    private let config = Config()

    /// Generates an MP4 video and returns the file URL.
    func generate(
        tournament: Tournament,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap_\(UUID().uuidString).mp4")

        // Clean up any leftover file at this path
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: bufferAttributes
        )

        writer.add(writerInput)
        guard writer.startWriting() else {
            throw VideoComposerError.cannotCreateWriter
        }
        writer.startSession(atSourceTime: .zero)

        // Calculate total frames based on level count
        let levelCount = latestPerLevel(for: tournament).count
        let totalDuration = titleDuration + (Double(max(levelCount, 1)) * secondsPerLevel) + recapDuration
        let totalFrames = Int(totalDuration * Double(config.fps))

        for frameIndex in 0..<totalFrames {
            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            let progress = Double(frameIndex) / Double(totalFrames - 1)
            onProgress(progress)

            guard let image = renderFrame(tournament: tournament, progress: progress) else {
                throw VideoComposerError.renderingFailed
            }

            guard let pixelBuffer = pixelBuffer(from: image) else {
                throw VideoComposerError.cannotCreatePixelBuffer
            }

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(config.fps))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw VideoComposerError.writingFailed
        }

        return outputURL
    }

    // MARK: - Timing Constants

    private let titleDuration: Double = 1.5
    private let secondsPerLevel: Double = 0.5
    private let recapDuration: Double = 2.0

    // MARK: - Frame Rendering

    private func renderFrame(tournament: Tournament, progress: Double) -> UIImage? {
        let view = VideoRecapView(
            tournament: tournament,
            progress: progress
        )
        let renderer = ImageRenderer(content:
            view.frame(width: config.proposedSize.width, height: config.proposedSize.height)
        )
        renderer.scale = 3.0
        return renderer.uiImage
    }

    // MARK: - Pixel Buffer

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            cgImage.width,
            cgImage.height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &buffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return pixelBuffer
    }

    // MARK: - Data Helpers

    func latestPerLevel(for tournament: Tournament) -> [StackEntry] {
        let entries = tournament.sortedStackEntries
        let grouped = Dictionary(grouping: entries) { $0.blindLevelNumber }
        return grouped.compactMap { (_, entriesForLevel) in
            entriesForLevel.max(by: { $0.timestamp < $1.timestamp })
        }
        .sorted { $0.blindLevelNumber < $1.blindLevelNumber }
    }
}
```

**Step 2: Verify the file compiles**

Open Xcode, build the project (Cmd+B). Fix any import or type issues.

**Step 3: Commit**

```bash
git add StackTrackerPro/Managers/VideoComposer.swift
git commit -m "feat: add VideoComposer core with AVAssetWriter and pixel buffer conversion"
```

---

### Task 2: VideoRecapView — The Per-Frame Canvas

Create the SwiftUI view that represents a single frame of the video, driven by a `progress` parameter that transitions through title → graph → recap.

**Files:**
- Create: `StackTrackerPro/Views/Sharing/VideoRecapView.swift`

**Step 1: Create VideoRecapView with three-act structure**

```swift
import SwiftUI
import Charts

struct VideoRecapView: View {
    let tournament: Tournament
    let progress: Double

    // MARK: - Timing (matches VideoComposer)

    private var levelCount: Int {
        latestPerLevel.count
    }

    private var totalDuration: Double {
        1.5 + (Double(max(levelCount, 1)) * 0.5) + 2.0
    }

    /// Map progress (0–1) to seconds elapsed
    private var elapsed: Double {
        progress * totalDuration
    }

    // Act boundaries in seconds
    private var titleEnd: Double { 1.5 }
    private var graphEnd: Double { 1.5 + Double(max(levelCount, 1)) * 0.5 }

    // MARK: - Data

    private var latestPerLevel: [StackEntry] {
        let entries = tournament.sortedStackEntries
        let grouped = Dictionary(grouping: entries) { $0.blindLevelNumber }
        return grouped.compactMap { (_, group) in
            group.max(by: { $0.timestamp < $1.timestamp })
        }
        .sorted { $0.blindLevelNumber < $1.blindLevelNumber }
    }

    private var sortedPhotos: [ChipStackPhoto] {
        (tournament.chipStackPhotos ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    private var chipRange: ClosedRange<Int> {
        let chips = latestPerLevel.map(\.chipCount)
        let minVal = max(0, (chips.min() ?? 0) - 1000)
        let maxVal = (chips.max() ?? tournament.startingChips) + 1000
        return minVal...max(minVal + 1, maxVal)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            ShareCardBackground()

            if elapsed < titleEnd {
                titleCard
                    .opacity(titleOpacity)
            } else if elapsed < graphEnd {
                graphCard
            } else {
                recapCard
                    .opacity(recapOpacity)
            }
        }
    }

    // MARK: - Title Card

    private var titleOpacity: Double {
        // Fade in over first 0.5s
        let fadeIn = min(elapsed / 0.5, 1.0)
        // Fade out over last 0.3s of title
        let remaining = titleEnd - elapsed
        let fadeOut = remaining < 0.3 ? remaining / 0.3 : 1.0
        return fadeIn * fadeOut
    }

    private var titleCard: some View {
        VStack(spacing: 12) {
            Spacer()

            Text(tournament.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if !tournament.venueName.isEmpty {
                Text(tournament.venueName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textSecondary)
            }

            if let date = tournament.endDate ?? Optional(tournament.startDate) {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textSecondary.opacity(0.7))
            }

            Spacer()

            AppWatermark(compact: false)
                .padding(.bottom, 20)
        }
        .padding(20)
    }

    // MARK: - Graph Card

    /// How many levels to show at current elapsed time
    private var visibleLevelCount: Int {
        let graphElapsed = elapsed - titleEnd
        let levelsToShow = Int(graphElapsed / 0.5) + 1
        return min(levelsToShow, levelCount)
    }

    /// The photo to display inline, if any
    private var activePhoto: ChipStackPhoto? {
        let graphElapsed = elapsed - titleEnd
        let currentLevelIndex = min(Int(graphElapsed / 0.5), levelCount - 1)
        guard currentLevelIndex >= 0, currentLevelIndex < latestPerLevel.count else { return nil }
        let currentLevel = latestPerLevel[currentLevelIndex]

        // Show photo for ~1 second after level appears
        let levelStartTime = Double(currentLevelIndex) * 0.5
        let timeSinceLevelStart = graphElapsed - levelStartTime
        guard timeSinceLevelStart >= 0, timeSinceLevelStart < 1.0 else { return nil }

        return sortedPhotos.first { $0.blindLevel == (tournament.displayLevelNumbers[currentLevel.blindLevelNumber] ?? currentLevel.blindLevelNumber) }
    }

    /// Opacity for the photo overlay (fades in/out)
    private var photoOpacity: Double {
        let graphElapsed = elapsed - titleEnd
        let currentLevelIndex = min(Int(graphElapsed / 0.5), levelCount - 1)
        let levelStartTime = Double(currentLevelIndex) * 0.5
        let timeSinceLevelStart = graphElapsed - levelStartTime

        // Fade in over 0.15s, hold, fade out over 0.2s before 1.0s mark
        let fadeIn = min(timeSinceLevelStart / 0.15, 1.0)
        let remaining = 1.0 - timeSinceLevelStart
        let fadeOut = remaining < 0.2 ? remaining / 0.2 : 1.0
        return fadeIn * fadeOut
    }

    private var graphCard: some View {
        let visibleData = Array(latestPerLevel.prefix(visibleLevelCount))

        return VStack(spacing: 12) {
            ShareCardHeader(
                eventName: tournament.name,
                venueName: tournament.venueName
            )

            GoldDivider()

            ZStack(alignment: .topTrailing) {
                // Chart
                Chart {
                    ForEach(Array(visibleData.enumerated()), id: \.offset) { index, entry in
                        AreaMark(
                            x: .value("Index", index),
                            y: .value("Chips", entry.chipCount)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.goldAccent.opacity(0.3), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    ForEach(Array(visibleData.enumerated()), id: \.offset) { index, entry in
                        LineMark(
                            x: .value("Index", index),
                            y: .value("Chips", entry.chipCount)
                        )
                        .foregroundStyle(Color.goldAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Index", index),
                            y: .value("Chips", entry.chipCount)
                        )
                        .foregroundStyle(entry.mZone.color)
                        .symbolSize(40)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let chips = value.as(Int.self) {
                                Text(formatChipsShort(chips))
                                    .font(.caption2)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
                .chartXScale(domain: 0...max(levelCount - 1, 1))
                .chartYScale(domain: chipRange)
                .frame(height: 350)

                // Inline photo overlay
                if let photo = activePhoto, let uiImage = UIImage(data: photo.imageData) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 4)

                        Text("Lvl \(photo.blindLevel)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(8)
                    .opacity(photoOpacity)
                }
            }

            GoldDivider()

            // Current level info
            if visibleLevelCount > 0, visibleLevelCount <= latestPerLevel.count {
                let currentEntry = latestPerLevel[visibleLevelCount - 1]
                let displayLevel = tournament.displayLevelNumbers[currentEntry.blindLevelNumber] ?? currentEntry.blindLevelNumber
                HStack {
                    Text("Level \(displayLevel)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.goldAccent)
                    Spacer()
                    Text(currentEntry.formattedChipCount)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                }
            }

            Spacer()

            AppWatermark(compact: false)
        }
        .padding(16)
    }

    // MARK: - Recap Card

    private var recapOpacity: Double {
        let recapElapsed = elapsed - graphEnd
        return min(recapElapsed / 0.4, 1.0)
    }

    private var recapCard: some View {
        VStack(spacing: 14) {
            ShareCardHeader(
                eventName: tournament.name,
                venueName: tournament.venueName
            )

            GoldDivider()

            // Hero section
            VStack(spacing: 4) {
                Text(positionText)
                    .font(PokerTypography.shareHero)
                    .foregroundColor(.goldAccent)

                Text(payoutText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }

            // Metrics row
            HStack(spacing: 0) {
                metricColumn(label: "Buy-in", value: "$\(tournament.totalInvestment.formatted())")
                metricColumn(label: "ROI", value: roiText)
                metricColumn(label: "Duration", value: tournament.durationFormatted)
                metricColumn(label: "Peak", value: formatChipsShort(peakStack))
            }

            GoldDivider()

            // Final chart (all data visible)
            MiniStackChartView(
                entries: tournament.sortedStackEntries,
                height: 120
            )

            GoldDivider()

            ShareCardFooter()
        }
        .padding(16)
    }

    // MARK: - Recap Helpers

    private var positionText: String {
        guard let pos = tournament.finishPosition else { return "Completed" }
        let suffix: String
        let ones = pos % 10
        let tens = (pos / 10) % 10
        if tens == 1 { suffix = "th" }
        else {
            switch ones {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(pos)\(suffix) Place"
    }

    private var payoutText: String {
        guard let p = tournament.payout, p > 0 else { return "$0" }
        return "$\(p.formatted())"
    }

    private var roiText: String {
        guard tournament.totalInvestment > 0, let payout = tournament.payout else { return "—" }
        let totalReturn = payout + (tournament.bountiesCollected * tournament.bountyAmount)
        let roi = (Double(totalReturn - tournament.totalInvestment) / Double(tournament.totalInvestment)) * 100
        return String(format: "%.0f%%", roi)
    }

    private var peakStack: Int {
        tournament.sortedStackEntries.map(\.chipCount).max() ?? tournament.startingChips
    }

    private func metricColumn(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(PokerTypography.shareValue)
                .foregroundColor(.textPrimary)
            Text(label)
                .font(PokerTypography.shareLabel)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatChipsShort(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000)
        } else if value >= 1000 {
            return String(format: "%.0fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}
```

**Step 2: Build in Xcode to verify compilation**

Run: Cmd+B. Resolve any type mismatches (check `tournament.venueName` is non-optional or guard appropriately).

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/Sharing/VideoRecapView.swift
git commit -m "feat: add VideoRecapView with title, animated graph, and recap acts"
```

---

### Task 3: VideoExportSheet — Progress UI & Share Flow

Create the sheet that shows generation progress, then presents the finished video for sharing.

**Files:**
- Create: `StackTrackerPro/Views/Sharing/VideoExportSheet.swift`

**Step 1: Create VideoExportSheet**

```swift
import SwiftUI
import AVKit

struct VideoExportSheet: View {
    let tournament: Tournament
    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var videoURL: URL?
    @State private var error: String?
    @State private var isGenerating = false
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
            .onDisappear {
                // Clean up temp file if not shared
                if let url = videoURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Generating State

    private var generatingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundColor(.goldAccent)

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
            // Video preview
            VideoPlayer(player: AVPlayer(url: url))
                .frame(width: 200, height: 355)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

            // Share button
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
```

**Step 2: Build in Xcode to verify compilation**

Run: Cmd+B.

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/Sharing/VideoExportSheet.swift
git commit -m "feat: add VideoExportSheet with progress bar, preview, and sharing"
```

---

### Task 4: Wire Up Entry Point in SessionRecapSheet

Add a "Create Video" button to the existing SessionRecapSheet, below the "Post to X" button.

**Files:**
- Modify: `StackTrackerPro/Views/Session/SessionRecapSheet.swift:15` (add state)
- Modify: `StackTrackerPro/Views/Session/SessionRecapSheet.swift:93` (add button)
- Modify: `StackTrackerPro/Views/Session/SessionRecapSheet.swift:123` (add sheet)

**Step 1: Add state variable for the video sheet**

After line 15 (`@State private var showXShare = false`), add:

```swift
@State private var showVideoExport = false
```

**Step 2: Add "Create Video" button after the "Post to X" button**

After the Post to X button block (after line 93, before the closing `}` of the VStack), add:

```swift
// Create Video button
if !tournament.sortedStackEntries.isEmpty {
    Button {
        showVideoExport = true
    } label: {
        HStack {
            Image(systemName: "film")
            Text("Create Video")
        }
        .font(.headline.weight(.semibold))
        .foregroundColor(.goldAccent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.goldAccent.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
        )
    }
    .padding(.horizontal, 24)
}
```

**Step 3: Add sheet presentation**

After line 123 (`.sheet(isPresented: $showXShare) { ... }`), add:

```swift
.sheet(isPresented: $showVideoExport) {
    VideoExportSheet(tournament: tournament)
}
```

**Step 4: Build and verify the button appears**

Run in simulator, complete a tournament with stack entries, verify the "Create Video" button appears on the recap sheet.

**Step 5: Commit**

```bash
git add StackTrackerPro/Views/Session/SessionRecapSheet.swift
git commit -m "feat: add Create Video button to session recap sheet"
```

---

### Task 5: End-to-End Testing & Polish

Test the full flow on a real tournament with multiple stack entries and chip photos, and fix any issues.

**Files:**
- May modify: `StackTrackerPro/Managers/VideoComposer.swift`
- May modify: `StackTrackerPro/Views/Sharing/VideoRecapView.swift`
- May modify: `StackTrackerPro/Views/Sharing/VideoExportSheet.swift`

**Step 1: Test with a completed tournament**

1. Open the app in simulator
2. Open a completed tournament from history (one with multiple stack entries and chip photos)
3. Tap the share/recap button
4. Tap "Create Video"
5. Verify: progress bar advances smoothly, video generates without crash

**Step 2: Verify video content**

1. After generation, verify the preview plays
2. Check: title card shows tournament name + venue
3. Check: graph animates progressively (not all at once)
4. Check: chip photos appear inline at correct levels
5. Check: recap card shows correct stats at the end
6. Check: tap Share, verify iOS share sheet appears with the MP4

**Step 3: Test edge cases**

- Tournament with only 1-2 stack entries (short video)
- Tournament with no chip photos (graph only, no photo overlays)
- Tournament with many entries (15+) — verify reasonable duration

**Step 4: Fix any issues found during testing**

Common issues to watch for:
- Chart Y-axis domain errors if all chip counts are the same — ensure `chipRange` has a non-zero range
- Photo matching by display level vs internal level — verify the `activePhoto` lookup matches correctly
- Memory pressure from rendering many frames — if needed, add autoreleasepool around the frame loop

**Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: polish video generation based on testing"
```

---

### Task 6: Final Commit & Cleanup

**Step 1: Remove any temp/debug code**

Search for print statements or debug flags added during testing.

**Step 2: Verify clean build**

Run: Cmd+B with no warnings on the new files.

**Step 3: Final commit if needed**

```bash
git add -A
git commit -m "chore: clean up video feature for release"
```
