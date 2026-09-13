import AppKit

/// Backs the sidebar. Mirrors Finder's sectioning (Favourites / Locations)
/// while keeping Dolphin's idea that places are user-editable and reorderable.
final class PlacesModel {

    struct Place {
        let name: String
        let url: URL
        let symbolName: String
        /// Every favourite can be reordered and removed, like Finder's sidebar;
        /// Locations (volumes) cannot.
        var isRemovable: Bool = false
        var isBuiltIn: Bool = false
    }

    struct Section {
        let title: String
        var places: [Place]
    }

    private(set) var sections: [Section] = []
    static let didChange = Notification.Name("PlacesModel.didChange")
    private func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    init() {
        rebuild()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumesChanged),
            name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumesChanged),
            name: NSWorkspace.didUnmountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumesChanged),
            name: NSWorkspace.didRenameVolumeNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func volumesChanged() {
        rebuild()
        notify()
    }

    func rebuild() {
        sections = [
            Section(title: "Favourites", places: favourites()),
            Section(title: "Locations", places: locations()),
        ]
    }

    // MARK: - Favourites

    /// One ordered list covering built-ins ("builtin:desktop") and user
    /// folders ("path:/Users/…"), persisted whole so any item can move.
    private let orderKey = "favouritesOrder"

    private struct BuiltIn {
        let key: String
        let symbol: String
        let url: URL?
    }

    private static func builtIns() -> [BuiltIn] {
        let fm = FileManager.default
        var out = [BuiltIn(key: "home", symbol: "house", url: fm.homeDirectoryForCurrentUser)]
        let standard: [(String, FileManager.SearchPathDirectory, String)] = [
            ("desktop", .desktopDirectory, "menubar.dock.rectangle"),
            ("documents", .documentDirectory, "doc"),
            ("downloads", .downloadsDirectory, "arrow.down.circle"),
            ("movies", .moviesDirectory, "film"),
            ("music", .musicDirectory, "music.note"),
            ("pictures", .picturesDirectory, "photo"),
            ("applications", .applicationDirectory, "square.grid.3x3"),
        ]
        for (key, dir, symbol) in standard {
            let url = fm.urls(for: dir, in: .userDomainMask).first
            out.append(BuiltIn(key: key, symbol: symbol, url: url.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }))
        }
        return out
    }

    private func storedOrder() -> [String] {
        if let order = UserDefaults.standard.stringArray(forKey: orderKey) { return order }
        return Self.builtIns().map { "builtin:" + $0.key }   // first run
    }

    private func saveOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: orderKey)
        rebuild(); notify()
    }

    /// Refs that resolved to a shown place, parallel to `sections[0].places`.
    private var favouriteRefs: [String] = []

    private func favourites() -> [Place] {
        let builtIns = Self.builtIns()
        var refs: [String] = []
        var places: [Place] = []
        for ref in storedOrder() {
            if ref.hasPrefix("builtin:") {
                let key = String(ref.dropFirst("builtin:".count))
                guard let b = builtIns.first(where: { $0.key == key }), let url = b.url else { continue }
                let name = key == "home" ? NSUserName() : url.lastPathComponent
                places.append(Place(name: name, url: url, symbolName: b.symbol, isRemovable: true, isBuiltIn: true))
            } else if ref.hasPrefix("path:") {
                let url = URL(fileURLWithPath: String(ref.dropFirst("path:".count)))
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                places.append(Place(name: url.lastPathComponent, url: url, symbolName: "folder", isRemovable: true))
            } else { continue }
            refs.append(ref)
        }
        favouriteRefs = refs
        return places
    }

    /// Position among the shown favourites (== the sidebar row order), or nil.
    func favouriteIndex(of url: URL) -> Int? {
        sections.first?.places.firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    func isFavourite(_ url: URL) -> Bool { favouriteIndex(of: url) != nil }

    /// Insert a folder at a favourites position (nil = append).
    func addFavourite(_ url: URL, at index: Int? = nil) {
        guard !isFavourite(url) else { return }
        var order = storedOrder()
        let ref = "path:" + url.standardizedFileURL.path
        if let index, favouriteRefs.indices.contains(index), let at = order.firstIndex(of: favouriteRefs[index]) {
            order.insert(ref, at: at)
        } else {
            order.append(ref)
        }
        saveOrder(order)
    }

    func removeFavourite(_ url: URL) {
        guard let i = favouriteIndex(of: url) else { return }
        var order = storedOrder()
        order.removeAll { $0 == favouriteRefs[i] }
        saveOrder(order)
    }

    /// Move within the shown favourites; indices are sidebar positions.
    func moveFavourite(from source: Int, to destination: Int) {
        guard favouriteRefs.indices.contains(source) else { return }
        var order = storedOrder()
        let ref = favouriteRefs[source]
        order.removeAll { $0 == ref }
        let clampedDest = min(max(destination, 0), favouriteRefs.count - 1)
        if clampedDest >= favouriteRefs.count - 1 && destination >= favouriteRefs.count - 1 {
            // Past the last shown favourite: append after it.
            if let lastRef = favouriteRefs.last(where: { $0 != ref }), let at = order.firstIndex(of: lastRef) {
                order.insert(ref, at: at + 1)
            } else {
                order.append(ref)
            }
        } else {
            // Before the item currently shown at `destination` (as seen after removal).
            var shown = favouriteRefs; shown.remove(at: source)
            let anchor = shown[min(destination, shown.count - 1)]
            let at = order.firstIndex(of: anchor) ?? order.count
            order.insert(ref, at: at)
        }
        saveOrder(order)
    }

    /// Back to the default built-in set and order.
    func resetFavourites() {
        UserDefaults.standard.removeObject(forKey: orderKey)
        rebuild(); notify()
    }

    // MARK: - Locations

    private func locations() -> [Place] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = v?.volumeName ?? url.lastPathComponent
            let removable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false)
            let internalVolume = v?.volumeIsInternal ?? true
            let symbol = Self.volumeSymbol(isLocal: v?.volumeIsLocal ?? true,
                                           isInternal: internalVolume, isRemovable: removable)
            return Place(name: name, url: url, symbolName: symbol)
        }
    }

    func isEjectable(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsRemovableKey,
                                       .volumeIsLocalKey, .isVolumeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return false }
        return Self.canEjectVolume(isVolume: v.isVolume ?? false, isLocal: v.volumeIsLocal ?? true,
                                   isRemovable: v.volumeIsRemovable ?? false,
                                   isEjectable: v.volumeIsEjectable ?? false)
    }

    /// A remote share can be unmounted without being a removable device.
    /// Only volume roots qualify, never an ordinary favourite within a disk.
    static func canEjectVolume(isVolume: Bool, isLocal: Bool, isRemovable: Bool, isEjectable: Bool) -> Bool {
        isVolume && (!isLocal || isRemovable || isEjectable)
    }

    static func volumeSymbol(isLocal: Bool, isInternal: Bool, isRemovable: Bool) -> String {
        if !isLocal { return "network" }
        return isRemovable ? "externaldrive"
            : isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"
    }
}
