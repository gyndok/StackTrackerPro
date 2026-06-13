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

    /// Dedicated temp subdirectory for exported recap videos.
    /// Files are intentionally NOT deleted when the export sheet dismisses
    /// (a ShareLink save may still be in flight) — stale files are cleaned
    /// at the start of the next export instead.
    nonisolated static var exportDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapVideos", isDirectory: true)
    }

    /// Generates an MP4 video and returns the file URL.
    func generate(
        tournament: Tournament,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let directory = Self.exportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.cleanStaleExports(in: directory)

        let outputURL = directory
            .appendingPathComponent("recap_\(UUID().uuidString).mp4")

        let frameWriter = try VideoFrameWriter(
            outputURL: outputURL,
            width: config.width,
            height: config.height
        )

        // Calculate total frames based on level count
        let levelCount = latestPerLevel(for: tournament).count
        let totalDuration = titleDuration + (Double(max(levelCount, 1)) * secondsPerLevel) + recapDuration
        let totalFrames = Int(totalDuration * Double(config.fps))

        for frameIndex in 0..<totalFrames {
            try Task.checkCancellation()

            let progress = Double(frameIndex) / Double(totalFrames - 1)
            onProgress(progress)

            // ImageRenderer requires the main actor — render here...
            guard let image = renderFrame(tournament: tournament, progress: progress),
                  let cgImage = image.cgImage else {
                throw VideoComposerError.renderingFailed
            }

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(config.fps))

            // ...then hop off the main actor for pixel-buffer conversion and
            // the H.264 append (nonisolated async runs on the global executor).
            try await frameWriter.append(cgImage, at: presentationTime)

            // Let pending main-actor UI work run so progress stays responsive.
            await Task.yield()
        }

        try await frameWriter.finish()

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

    // MARK: - Stale Export Cleanup

    /// Removes exported videos older than a day from the export directory.
    nonisolated private static func cleanStaleExports(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
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

// MARK: - VideoFrameWriter

/// Owns the AVAssetWriter pipeline. Its async methods are nonisolated, so
/// pixel-buffer creation/copy and H.264 appends run off the main actor —
/// only SwiftUI frame rendering stays on main.
///
/// @unchecked Sendable is sound because `generate(tournament:onProgress:)`
/// awaits each call before issuing the next, so the writer objects are never
/// touched concurrently.
private final class VideoFrameWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(outputURL: URL, width: Int, height: Int) throws {
        // Clean up any leftover file at this path
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: bufferAttributes
        )

        writer.add(writerInput)
        guard writer.startWriting() else {
            throw VideoComposerError.cannotCreateWriter
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ cgImage: CGImage, at presentationTime: CMTime) async throws {
        // Wait for writer to be ready
        while !writerInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        guard let pixelBuffer = Self.pixelBuffer(from: cgImage) else {
            throw VideoComposerError.cannotCreatePixelBuffer
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw VideoComposerError.writingFailed
        }
    }

    func finish() async throws {
        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw VideoComposerError.writingFailed
        }
    }

    // MARK: - Pixel Buffer

    private static func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
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
}
