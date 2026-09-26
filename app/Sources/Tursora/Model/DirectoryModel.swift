import Foundation

/// One row in the file list. A class so NSOutlineView can track expansion by
/// identity; nodes survive reloads (matched by URL) so expanded folders stay
/// expanded when the listing refreshes after a file operation.
final class FileNode {
    fileprivate(set) var item: FileItem
    /// Everything listed under this folder, unfiltered; nil until first expanded.
    fileprivate(set) var allChildren: [FileNode]?
    /// `allChildren` after hidden-file filtering and sorting.
    fileprivate(set) var children: [FileNode] = []

    init(_ item: FileItem) { self.item = item }
    var url: URL { item.url }
}

/// Loads and sorts one directory, plus any subfolders the user expands in
/// place. The root listing happens off the main thread; subfolder listings
/// are synchronous (they happen on expand, and local folders list fast).
final class DirectoryModel {

    enum SortKey: String {
        case name, size, kind, dateModified
        // Finder's ArrangeByMenu.nib also offers these three; the raw values
        // match GroupKey's so a saved file written before they existed still
        // decodes (DirectoryViewProperties falls back to .name on an unknown).
        case dateCreated, dateAdded, dateLastOpened
    }

    let provider: FileProvider

    /// Folder item counts and optional recursive sizes for this listing.
    let folderSizes = FolderSizes()

    init(provider: FileProvider) {
        self.provider = provider
        folderSizes.onUpdate = { [weak self] in self?.folderMetricsDidChange() }
    }

    /// New counts or sizes arrived. Only a Size sort has to reorder; every
    /// other arrangement just redraws the column.
    private func folderMetricsDidChange() {
        if sortKey == .size { resort() } else { onChange?() }
    }

    private(set) var url: URL?
    /// Root entries, unfiltered and unsorted, as last listed.
    private(set) var allNodes: [FileNode] = []
    /// Root entries as shown: hidden-filtered and sorted.
    private(set) var nodes: [FileNode] = []
    /// The same entries split into Finder-style groups (one untitled group when not grouping).
    private(set) var groups: [GroupNode] = [GroupNode(title: "", order: 0)]
    var isGrouped: Bool { groupKey != .none }
    var items: [FileItem] { nodes.map(\.item) }
    /// Bumped on every fresh listing, so views can tell a re-sort from a reload.
    private(set) var generation = 0

    var showHidden = false      { didSet { resort() } }
    /// Filter-bar text. Plain text matches case-insensitively anywhere in the
    /// name; `*` / `?` make it a wildcard pattern (Dolphin's rules).
    var nameFilter = ""         { didSet { if nameFilter != oldValue { resort() } } }
    var groupKey: GroupKey = .none { didSet { if groupKey != oldValue { resort() } } }
    /// Root entries before the name filter (hidden-file rule still applied) — for "3 of 12 items".
    var unfilteredCount: Int { (showHidden ? allNodes : allNodes.filter { !$0.item.isHidden }).count }
    var sortKey: SortKey = .name { didSet { resort() } }
    var ascending = true        { didSet { resort() } }

    /// Search results have no directory destination and never expand into unfiltered children.
    private(set) var isSearchResults = false
    var onReloadResults: (((() -> Void)?) -> Void)?

    func beginSearchResults() {
        loadToken += 1
        folderSizes.cancel()
        isSearchResults = true
        url = nil
        replaceSearchResults([])
    }

    func replaceSearchResults(_ items: [FileItem]) {
        guard isSearchResults else { return }
        allNodes = Self.merge(items, into: Self.index(allNodes))
        generation += 1
        resort()
    }

    private var loadToken = 0

    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    /// A successful filesystem listing, distinct from re-sorting existing rows.
    var onLoadSuccess: (() -> Void)?

    func load(_ target: URL, completion: (() -> Void)? = nil) {
        isSearchResults = false
        let changingDirectory = url?.standardizedFileURL != target.standardizedFileURL
        if changingDirectory { folderSizes.cancel() }
        url = target
        loadToken += 1
        let token = loadToken
        let provider = self.provider
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[FileItem], Error>
            do {
                result = .success(try provider.listDirectory(target))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }   // a newer load won
                switch result {
                case .success(let items):
                    // Reuse nodes by URL so the outline view keeps expansion state
                    // across a reload of the same directory.
                    let previous = changingDirectory ? [:] : Self.index(self.allNodes)
                    self.allNodes = Self.merge(items, into: previous)
                    self.generation += 1
                    self.resort()
                    self.onLoadSuccess?()
                case .failure(let error):
                    self.folderSizes.cancel()
                    self.allNodes = []
                    self.nodes = []
                    // Groups are a second view of the same listing. The icon
                    // grid uses them even with grouping turned off; retaining
                    // them leaves old, actionable rows beneath a failed path.
                    self.groups = Grouping.split([], by: self.groupKey)
                    self.generation += 1
                    self.onError?(error)
                    self.onChange?()
                }
                completion?()
            }
        }
    }

    /// Change both sort parameters with a single re-sort.
    func setSort(key: SortKey, ascending: Bool) {
        guard key != sortKey || ascending != self.ascending else { return }
        self.sortKey = key            // triggers a resort via didSet …
        if ascending != self.ascending {
            self.ascending = ascending   // … and at most one more
        }
    }

    func reload(completion: (() -> Void)? = nil) {
        if isSearchResults { onReloadResults?(completion); return }
        guard let url else { return }
        load(url, completion: completion)
    }

    // MARK: - Tree

    /// Lists a folder's children the first time (or again with `refresh`),
    /// applying the current filter and sort. Synchronous.
    @discardableResult
    func loadChildren(of node: FileNode, refresh: Bool = false) -> [FileNode] {
        guard !isSearchResults, node.item.isNavigable else { return [] }
        if node.allChildren == nil || refresh {
            let listed = (try? provider.listDirectory(node.url)) ?? []
            node.allChildren = Self.merge(listed, into: Self.index(node.allChildren ?? []))
            node.children = arrange(node.allChildren!)
        }
        return node.children
    }

    /// Finds a node anywhere in the loaded tree.
    func node(for url: URL) -> FileNode? {
        let target = url.standardizedFileURL
        func search(_ list: [FileNode]) -> FileNode? {
            for n in list {
                if n.url.standardizedFileURL == target { return n }
                if let hit = search(n.children) { return hit }
            }
            return nil
        }
        return search(nodes)
    }

    // MARK: - Private

    private static func index(_ nodes: [FileNode]) -> [URL: FileNode] {
        Dictionary(nodes.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// New listing → nodes, keeping existing node objects (and their loaded
    /// children) where the URL is unchanged.
    private static func merge(_ items: [FileItem], into previous: [URL: FileNode]) -> [FileNode] {
        items.map { item in
            if let old = previous[item.url.standardizedFileURL] {
                old.item = item
                return old
            }
            return FileNode(item)
        }
    }

    private func resort() {
        nodes = arrange(allNodes)
        groups = Grouping.split(nodes, by: groupKey)
        // Recursive results have no directory to walk cheaply; they get counts only.
        folderSizes.request(visibleFolders(nodes), allowsRecursiveSizes: !isSearchResults)
        onChange?()
    }

    /// Every folder row on screen, including the ones inside expanded folders.
    private func visibleFolders(_ list: [FileNode]) -> [FileItem] {
        var out: [FileItem] = []
        for node in list {
            if node.item.isNavigable { out.append(node.item) }
            if !node.children.isEmpty { out += visibleFolders(node.children) }
        }
        return out
    }

    /// Hidden-file filter + sort, applied to one level. Recurses into loaded
    /// subfolders so a sort change reorders every visible level.
    private func arrange(_ list: [FileNode]) -> [FileNode] {
        var visible = showHidden ? list : list.filter { !$0.item.isHidden }
        if !nameFilter.isEmpty { visible = visible.filter { Self.matches($0.item.name, filter: nameFilter) } }
        visible.sort { compare($0.item, $1.item) }
        for n in visible where n.allChildren != nil {
            n.children = arrange(n.allChildren!)
        }
        return visible
    }

    static func matches(_ name: String, filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        if filter.contains("*") || filter.contains("?") {
            return NSPredicate(format: "SELF LIKE[c] %@", "*" + filter + "*").evaluate(with: name)
        }
        return name.localizedCaseInsensitiveContains(filter)
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> Bool {
        guard a.url.standardizedFileURL != b.url.standardizedFileURL else { return false }
        let nameOrder = a.name.localizedStandardCompare(b.name)
        // Recursive results can have equal names. Their real paths provide a
        // stable, strict tie-breaker in either sorting direction.
        let nameAscending = nameOrder == .orderedSame
            ? a.url.path.compare(b.url.path) == .orderedAscending : nameOrder == .orderedAscending
        // Finder keeps folders on top only "In windows when sorting by name"
        // (PreferencesWindow.nib). Under every other key folders take part in the
        // sort like any other item, so a recently changed folder appears next to
        // the files changed at the same time. See D76, which supersedes D16.
        if sortKey == .name, a.isNavigable != b.isNavigable {
            return a.isNavigable          // ahead of files in either direction
        }
        let ordered: Bool
        switch sortKey {
        case .name:
            ordered = nameAscending
        case .size:
            // Folders sort by whatever has been measured for them; until a
            // value arrives they stay together ahead of the measured ones.
            let sa = folderSizes.sortValue(for: a) ?? -1
            let sb = folderSizes.sortValue(for: b) ?? -1
            ordered = sa == sb
                ? nameAscending
                : sa < sb
        case .kind:
            let c = a.kindDescription.localizedStandardCompare(b.kindDescription)
            ordered = c == .orderedSame
                ? nameAscending
                : c == .orderedAscending
        case .dateModified:
            let da = a.modificationDate ?? .distantPast
            let db = b.modificationDate ?? .distantPast
            ordered = da == db
                ? nameAscending
                : da < db
        case .dateCreated:
            return Self.compareDates(a.creationDate, b.creationDate,
                                     nameAscending: nameAscending, ascending: ascending)
        case .dateAdded:
            return Self.compareDates(a.addedDate, b.addedDate,
                                     nameAscending: nameAscending, ascending: ascending)
        case .dateLastOpened:
            return Self.compareDates(a.accessDate, b.accessDate,
                                     nameAscending: nameAscending, ascending: ascending)
        }
        return ascending ? ordered : !ordered
    }

    /// The three keys Finder added after Date Modified. An item with no date
    /// sinks to the bottom in *both* directions, the way folders always lead:
    /// reversing the order must not promote "no date" to the top.
    static func compareDates(_ a: Date?, _ b: Date?, nameAscending: Bool, ascending: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return ascending ? nameAscending : !nameAscending
        case (nil, _): return false
        case (_, nil): return true
        case (let da?, let db?):
            let ordered = da == db ? nameAscending : da < db
            return ascending ? ordered : !ordered
        }
    }
}
