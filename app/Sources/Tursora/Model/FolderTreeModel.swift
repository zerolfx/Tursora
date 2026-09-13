import Foundation
import Darwin

/// A lazy folder-only tree. The UI never enumerates directories, and expanding
/// a node never recursively scans its descendants.
final class FolderTreeModel {
    final class Node: NSObject {
        let url: URL
        let name: String
        var children: [Node]?
        var isLoading = false
        var error: String?
        fileprivate var refreshRequested = false
        fileprivate var request = UUID()
        fileprivate var completions: [() -> Void] = []
        init(url: URL, name: String) { self.url = url; self.name = name }
    }

    let provider: FileProvider
    private(set) var root: Node?
    private(set) var isActive = false
    private(set) var location: URL?
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    var showsHiddenFolders = false { didSet { if oldValue != showsHiddenFolders { reset() } } }
    var limitsToHome = true { didSet { if oldValue != limitsToHome { reset() } } }
    private var generation = UUID()
    private var revealGeneration = UUID()
    private var needsSystemPrivateAncestor = false
    private var watcher: DirectoryWatcher?
    private var observer: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?

    init(provider: FileProvider) {
        self.provider = provider
        observer = NotificationCenter.default.addObserver(forName: .tursoraDirectoriesChanged, object: nil, queue: .main) { [weak self] note in
            self?.directoriesChanged(note.userInfo?["directories"] as? [URL] ?? [])
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        refreshWork?.cancel()
        abandonPendingNodes()
    }

    static func rootURL(for location: URL, home: URL, limitsToHome: Bool) -> URL {
        let path = location.standardizedFileURL.path
        let home = home.standardizedFileURL
        return limitsToHome && (path == home.path || path.hasPrefix(home.path + "/"))
            ? home : URL(fileURLWithPath: "/", isDirectory: true)
    }

    static func folders(from items: [FileItem], showsHidden: Bool, includePrivateAncestor: Bool = false) -> [FileItem] {
        items.filter { $0.isNavigable && (showsHidden || !$0.isHidden || (includePrivateAncestor && $0.url.path == "/private")) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { reset() }
        else {
            generation = UUID(); revealGeneration = UUID()
            refreshWork?.cancel(); watcher = nil
            for node in loadedNodes { node.isLoading = false; node.completions.removeAll() }
        }
    }

    func follow(_ url: URL?, completion: (([Node]) -> Void)? = nil) {
        location = url?.standardizedFileURL
        revealGeneration = UUID()
        guard isActive, let location else { completion?([]); return }
        let expected = Self.rootURL(for: location, home: provider.homeURL, limitsToHome: limitsToHome)
        if root?.url.path != expected.path { replaceRoot(expected) }
        guard let root else { completion?([]); return }
        let token = revealGeneration
        if root.url.path == "/" {
            // /var and /tmp are aliases whose directory entries are symlinks,
            // not ordinary folder nodes. Foundation deliberately shortens even
            // resolvingSymlinksInPath back to those aliases on macOS. Resolve
            // off the UI thread and reveal the actual /private/... ancestors.
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak root] in
                let components = Self.physicalPathComponents(location)
                DispatchQueue.main.async { [weak self, weak root] in
                    guard let self, let root, self.root === root, self.isActive, token == self.revealGeneration else { return }
                    // /private itself is hidden. Keep only this required
                    // system ancestor visible while following /tmp or /var;
                    // the user's Show Hidden Folders choice remains intact.
                    let needsPrivate = components.dropFirst().first == "private"
                    if self.needsSystemPrivateAncestor != needsPrivate {
                        self.needsSystemPrivateAncestor = needsPrivate
                        if root.children != nil { self.load(root, refresh: true) }
                    }
                    self.revealLocation(root, components: components, token: token, completion: completion)
                }
            }
        } else {
            revealLocation(root, components: location.pathComponents, token: token, completion: completion)
        }
    }

    private static func physicalPathComponents(_ url: URL) -> [String] {
        guard let bytes = realpath(url.path, nil) else { return url.pathComponents }
        defer { free(bytes) }
        return URL(fileURLWithPath: String(cString: bytes)).pathComponents
    }

    private func revealLocation(_ root: Node, components: [String], token: UUID, completion: (([Node]) -> Void)?) {
        let remaining = components.dropFirst(root.url.pathComponents.count)
        // A malformed/deep logical location cannot force an unbounded chain.
        guard remaining.count <= 256 else { completion?([]); return }
        reveal(root, remaining: Array(remaining), ancestors: [], token: token, completion: completion)
    }

    private func reveal(_ node: Node, remaining: [String], ancestors: [Node], token: UUID,
                        completion: (([Node]) -> Void)?) {
        guard token == revealGeneration, isActive else { return }
        let path = ancestors + [node]
        guard let name = remaining.first else { completion?(path); return }
        load(node) { [weak self, weak node] in
            guard let self, let node, token == self.revealGeneration, self.isActive else { return }
            guard let child = node.children?.first(where: { $0.url.lastPathComponent == name }) else { completion?([]); return }
            self.reveal(child, remaining: Array(remaining.dropFirst()), ancestors: path, token: token, completion: completion)
        }
    }

    func load(_ node: Node, refresh: Bool = false, completion: (() -> Void)? = nil) {
        guard isActive, contains(node) else { completion?(); return }
        if let completion { node.completions.append(completion) }
        guard !node.isLoading else { if refresh { node.refreshRequested = true }; return }
        if !refresh, node.children != nil { finish(node); return }
        node.isLoading = true
        let token = generation
        let request = UUID()
        node.request = request
        let provider = provider
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak node] in
            guard let node else { return }
            let result = Result { try provider.listDirectory(node.url) }
            DispatchQueue.main.async { [weak self, weak node] in
                guard let node, node.request == request else { return }
                guard let self, self.isActive, self.generation == token, self.contains(node) else {
                    // A refreshed parent can discard this loading descendant.
                    // Its reveal callback retains an ancestor path, so release
                    // that cycle even though the node is no longer in the tree.
                    // A newer request owns its callbacks and must be untouched.
                    node.completions.removeAll()
                    node.isLoading = false
                    node.refreshRequested = false
                    return
                }
                node.isLoading = false
                switch result {
                case .success(let rawItems):
                    let items = Self.folders(from: rawItems, showsHidden: self.showsHiddenFolders,
                                             includePrivateAncestor: self.needsSystemPrivateAncestor)
                    let old = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.url.path, $0) })
                    node.children = items.map { old[$0.url.path] ?? Node(url: $0.url, name: $0.name) }
                    node.error = nil
                    self.lastError = nil
                case .failure(let error):
                    node.children = []
                    node.error = error.localizedDescription
                    self.lastError = "\(node.name): \(error.localizedDescription)"
                }
                self.onChange?()
                if node.refreshRequested {
                    node.refreshRequested = false
                    self.load(node, refresh: true)
                } else if !node.isLoading { self.finish(node) }
            }
        }
    }

    func refresh() {
        guard isActive else { return }
        // Capture the nodes before completions can replace their child lists.
        let nodes = loadedNodes.filter { $0.children != nil || $0.isLoading || $0 === root }
        for node in nodes { load(node, refresh: true) }
    }

    var loadedNodes: [Node] {
        guard let root else { return [] }
        var result = [root]
        var index = 0
        while index < result.count {
            result.append(contentsOf: result[index].children ?? [])
            index += 1
        }
        return result
    }

    private func contains(_ node: Node) -> Bool { loadedNodes.contains { $0 === node } }
    private func finish(_ node: Node) {
        let callbacks = node.completions
        node.completions.removeAll()
        callbacks.forEach { $0() }
    }
    private func reset() {
        guard isActive else { return }
        let current = location ?? provider.homeURL
        replaceRoot(Self.rootURL(for: current, home: provider.homeURL, limitsToHome: limitsToHome))
        follow(current)
    }
    private func replaceRoot(_ url: URL) {
        abandonPendingNodes()
        generation = UUID()
        watcher = nil
        lastError = nil
        root = Node(url: url, name: url.path == "/" ? "/" : url.lastPathComponent)
        if provider is LocalFileProvider {
            watcher = DirectoryWatcher(directory: url) { [weak self] paths in
                self?.directoriesChanged(paths.map { URL(fileURLWithPath: $0) })
            }
        }
        onChange?()
        if let root { load(root) }
    }
    private func abandonPendingNodes() {
        // Reveal callbacks retain their ancestor path. Break that path cycle
        // before old roots become unreachable and stale workers return early.
        for node in loadedNodes {
            node.completions.removeAll()
            node.isLoading = false
            node.refreshRequested = false
        }
    }
    private func directoriesChanged(_ directories: [URL]) {
        guard isActive else { return }
        let paths = Set(loadedNodes.filter { $0.children != nil || $0.isLoading }.map { $0.url.resolvingSymlinksInPath().path })
        guard directories.contains(where: { paths.contains($0.standardizedFileURL.path) || paths.contains($0.deletingLastPathComponent().standardizedFileURL.path) }) else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
