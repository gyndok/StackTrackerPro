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
