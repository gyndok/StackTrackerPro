# Tournament Recap Video — Design

## Summary

Generate a short (~10-15 second) silent vertical video (9:16, 1080x1920) from a completed tournament's stack graph and chip stack photos. The graph animates level-by-level, chip photos appear inline at their corresponding levels, and a recap card closes the video. Shared via standard iOS share sheet.

## Video Structure

Three acts driven by a progress parameter (0.0 → 1.0):

| Act | Progress | Duration | Content |
|-----|----------|----------|---------|
| Title card | 0.0–0.1 | ~1.5s | Tournament name, venue, date. Fades in. Uses ShareCardHeader style. |
| Animated graph | 0.1–0.85 | ~7-12s | Graph draws level-by-level. Each level holds ~0.5s. Photos appear inline. |
| Recap card | 0.85–1.0 | ~2s | Final stats (position, payout, ROI, peak, duration). Fades in. |

Total duration scales with level count. At 30fps, roughly 300-450 frames.

## Architecture

### New Files

| File | Purpose |
|------|---------|
| `Managers/VideoComposer.swift` | Core engine: renders frames via ImageRenderer, writes MP4 via AVAssetWriter |
| `Views/Sharing/VideoRecapView.swift` | SwiftUI canvas rendered per-frame, driven by progress parameter |
| `Views/Sharing/VideoExportSheet.swift` | UI: progress bar during generation, then preview + share |

### Generation Pipeline

1. `VideoExportSheet` presents from share/recap area
2. Calls `VideoComposer.generate(tournament:)` async
3. VideoComposer creates AVAssetWriter targeting temp MP4
4. Loops through frame timestamps at 30fps
5. Each frame: calculate progress → render `VideoRecapView(progress:)` via ImageRenderer → convert to CVPixelBuffer → append to writer
6. On completion, present video for sharing via UIActivityViewController

### Graph Animation

The VideoRecapView receives an `entryCount` parameter derived from progress. For each frame during the graph phase, it passes a truncated slice of `latestPerLevel` entries to a chart view:

- Y-axis domain fixed to tournament's overall min/max (no rescaling between frames)
- X-axis domain fixed to all levels from the start (points appear progressively)
- Same styling as StackGraphView: gold line, area gradient, M-zone colored dots, Catmull-Rom interpolation

### Photo Overlay

When the currently drawing level matches a `ChipStackPhoto.blindLevel`:
- Photo appears as a rounded thumbnail (~30% of frame width) in the upper-right of the graph area
- Includes subtle shadow and "Lvl N" badge
- Holds for ~1 second of frames, then fades out before next level

### Transitions

Opacity-based fades between acts. No complex transitions.

## Output Specs

- Resolution: 1080x1920 (9:16 vertical)
- Frame rate: 30 fps
- Codec: H.264
- Audio: None
- File size: ~2-5 MB estimated
- Storage: Temp directory, cleaned up after sharing

## Entry Point & UX

### Access

New "Create Video" button in the share/recap area alongside existing share card options. Film icon + label, gold accent style.

### User Flow

1. Tap "Create Video"
2. Sheet presents with progress bar ("Creating your recap...") and cancel button
3. Generation runs async (~3-8 seconds)
4. Sheet transitions to: video preview thumbnail, Share button (→ iOS share sheet), Done button

### Error Handling

- No stack entries: button disabled with note "Record stack updates to create a video"
- Generation failure: alert with retry option

### Scope Boundaries (v1)

- No user-configurable settings (duration, music, etc.)
- No audio
- Single format (vertical 9:16)
- One-tap generation, no customization UI

## Reused Components

- `ShareCardBackground`, `AppWatermark`, `ShareCardHeader`, `ShareCardFooter`
- `MiniStackChartView` pattern for incremental chart building
- `SessionRecapCardView` layout for closing card
- `ShareCardRenderer` ImageRenderer pattern
- Theme colors and `PokerTypography`
- `ChipStackPhoto` model for photo data

## Dependencies to Add

- `AVFoundation` (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)
- `CoreVideo` (CVPixelBuffer creation)
