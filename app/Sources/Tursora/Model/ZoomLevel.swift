import Foundation

/// `CaseIterable` so a check can walk every mode instead of listing two by
/// hand and silently skipping a third.
enum ViewMode: String, CaseIterable {
    case details, icons, columns
}

/// Dolphin-style zoom steps. Each view mode has its own ladder of icon sizes;
/// each directory property record keeps a separate step for both modes.
enum ZoomLevel {
    static let iconSizes: [CGFloat] = [32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 512]
    static let detailsSizes: [CGFloat] = [16, 22, 32, 48, 64]
    /// Columns are rows too, so they share the list ladder; Finder's column
    /// view defaults to a 24 pt row, which is the 22 pt icon step here.
    static let columnsSizes: [CGFloat] = detailsSizes

    /// Every accessor here is a `switch` on purpose. Two of them used to be
    /// ternaries that disagreed on the fall-through case — `== .icons` in one,
    /// `== .details` in the other — so a third mode read one ladder's index
    /// against the other ladder's length. The compiler now refuses a mode
    /// that any of them forgets.
    static func sizes(for mode: ViewMode) -> [CGFloat] {
        switch mode {
        case .icons: return iconSizes
        case .details: return detailsSizes
        case .columns: return columnsSizes
        }
    }

    static func defaultIndex(for mode: ViewMode) -> Int {
        switch mode {
        case .icons: return 2       // 64 pt
        case .details: return 0     // 16 pt
        case .columns: return 1     // 22 pt, a 24 pt row like Finder's
        }
    }

    static func clamp(_ index: Int, for mode: ViewMode) -> Int {
        min(max(index, 0), sizes(for: mode).count - 1)
    }

    /// Previews (thumbnails) make sense from this size up — below it a
    /// thumbnail is an unreadable smudge and the type icon says more.
    static let previewThreshold: CGFloat = 32
}

