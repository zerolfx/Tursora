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

/// Legacy defaults imported when the application directory-view library is absent.
enum ViewPreferences {
    private static let defaults = UserDefaults.standard

    static var viewMode: ViewMode {
        get { ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .details }
        set { defaults.set(newValue.rawValue, forKey: "viewMode") }
    }

    static func zoomIndex(for mode: ViewMode) -> Int {
        let key = "zoom." + mode.rawValue
        guard defaults.object(forKey: key) != nil else { return ZoomLevel.defaultIndex(for: mode) }
        return ZoomLevel.clamp(defaults.integer(forKey: key), for: mode)
    }

    static func setZoomIndex(_ index: Int, for mode: ViewMode) {
        defaults.set(index, forKey: "zoom." + mode.rawValue)
    }

    static var groupKey: GroupKey {
        get { GroupKey(rawValue: defaults.string(forKey: "groupKey") ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: "groupKey") }
    }
    /// The key "Use Groups" returns to when toggled back on.
    static var lastGroupKey: GroupKey {
        get { GroupKey(rawValue: defaults.string(forKey: "lastGroupKey") ?? "") ?? .kind }
        set { defaults.set(newValue.rawValue, forKey: "lastGroupKey") }
    }

    static var showPreviews: Bool {
        get { defaults.object(forKey: "showPreviews") == nil ? true : defaults.bool(forKey: "showPreviews") }
        set { defaults.set(newValue, forKey: "showPreviews") }
    }
}
