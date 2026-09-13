import Foundation

enum ViewMode: String {
    case details, icons
}

/// Dolphin-style zoom steps. Each view mode has its own ladder of icon sizes;
/// each directory property record keeps a separate step for both modes.
enum ZoomLevel {
    static let iconSizes: [CGFloat] = [32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 512]
    static let detailsSizes: [CGFloat] = [16, 22, 32, 48, 64]

    static func sizes(for mode: ViewMode) -> [CGFloat] {
        mode == .icons ? iconSizes : detailsSizes
    }

    static func defaultIndex(for mode: ViewMode) -> Int { mode == .icons ? 2 : 0 }   // 64pt / 16pt

    static func clamp(_ index: Int, for mode: ViewMode) -> Int {
        min(max(index, 0), sizes(for: mode).count - 1)
    }

    /// Previews (thumbnails) make sense from this size up — below it a
    /// thumbnail is an unreadable smudge and the type icon says more.
    static let previewThreshold: CGFloat = 32
}

