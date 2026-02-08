import SwiftUI
import UIKit
import CoreTransferable

// MARK: - Share Card Size

enum ShareCardSize: String, CaseIterable {
    case stories = "Stories"
    case square = "Square"

    /// Full export resolution (rendered at @3x)
    var exportSize: CGSize {
        switch self {
        case .stories: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }

    /// SwiftUI proposed size (export ÷ 3 for @3x rendering)
    var proposedSize: CGSize {
        CGSize(width: exportSize.width / 3, height: exportSize.height / 3)
    }
}

// MARK: - Share Card Renderer

@MainActor
struct ShareCardRenderer {
    /// Renders any SwiftUI view to a UIImage at 3x scale.
    static func render<V: View>(_ view: V, size: ShareCardSize) -> UIImage? {
        let renderer = ImageRenderer(content:
            view
                .frame(width: size.proposedSize.width, height: size.proposedSize.height)
        )
        renderer.scale = 3.0
        return renderer.uiImage
    }
}

// MARK: - Shareable Image (Transferable)

struct ShareableImage: Transferable {
    let image: Image
    let uiImage: UIImage

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.image)
    }
}
