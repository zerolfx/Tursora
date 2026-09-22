import Foundation
import UniformTypeIdentifiers

/// The browsable shape of an archive, built from its table of contents alone.
///
/// `tar -tvf` reports a flat list of entry names, and a ZIP is under no
/// obligation to store directory records at all — a Python-written archive
/// stores none (measured). So the hierarchy is synthesized here, and every
/// rule below is a measured property of what bsdtar will actually do on
/// extraction rather than a convention: if the tree disagrees with the
/// extractor, a row appears that can never be opened.
///
/// Pure: no filesystem, no process, no main thread. See
/// docs/research/lazy-zip-browsing.md.
struct ArchiveTree {
    struct Node: Equatable {
        /// The last path component, as shown.
        let name: String
        /// Where the entry lands under the extraction root, after bsdtar's own
        /// rewrites. Empty for the root itself.
        let path: String
        /// What to hand bsdtar to extract it: the archive's own spelling, with
        /// glob metacharacters escaped. Differs from `path` exactly where
        /// bsdtar rewrites, e.g. `/etc/evil.txt` is the member and
        /// `etc/evil.txt` is the path.
        let member: String
        let kind: ArchiveEntrySummary.Kind
        let uncompressedSize: Int64
        /// A bundle, decided by extension. It has to be extracted whole or the
        /// application or document it represents is broken.
        let isPackage: Bool
        /// False for an entry bsdtar will refuse or that cannot be addressed:
        /// a `..` component, or a name the listing had to escape. Such a row is
        /// still shown, and is inert, exactly like an escaping symbolic link.
        let isExtractable: Bool
        /// Direct children, for seeding the item count of a directory whose
        /// contents are not on disk yet.
        let childCount: Int

        var isDirectory: Bool { kind == .directory }
    }

    private var nodes: [String: Node] = [:]
    private var childPaths: [String: [String]] = [:]

    init(entries: [ArchiveEntrySummary]) {
        // Two passes: place every real entry first, so a file always beats a
        // directory implied by some other entry's path, then index children.
        var order: [String] = []
        for entry in entries {
            guard let normalized = Self.normalize(entry.name) else { continue }
            let extractable = Self.isAddressable(entry.name) && !normalized.escapesRoot
            Self.synthesizeAncestors(of: normalized.components, into: &nodes, order: &order)
            let path = normalized.components.joined(separator: "/")
            guard !path.isEmpty else { continue }
            let node = Node(name: normalized.components.last ?? entry.name,
                            path: path,
                            member: Self.escapeMember(entry.name),
                            kind: entry.kind,
                            uncompressedSize: entry.uncompressedSize,
                            isPackage: entry.kind == .directory && Self.isPackage(path),
                            isExtractable: extractable,
                            childCount: 0)
            // Last wins: two entries of one name in a ZIP are legal, and
            // extraction yields the later one's content (measured).
            if nodes[path] == nil { order.append(path) }
            nodes[path] = node
        }
        // A directory synthesized from some path may also be a package.
        for path in order where nodes[path]?.kind == .directory && nodes[path]?.isPackage == false {
            if Self.isPackage(path) { nodes[path] = Self.marked(nodes[path]!, package: true) }
        }
        var counts: [String: Int] = [:]
        for path in order {
            let parent = Self.parent(of: path)
            childPaths[parent, default: []].append(path)
            counts[parent, default: 0] += 1
        }
        for (path, count) in counts where nodes[path] != nil {
            nodes[path] = Self.marked(nodes[path]!, childCount: count)
        }
    }

    // MARK: - Queries

    func node(at path: String) -> Node? { nodes[Self.key(path)] }

    /// Direct children, or nil when the path is not a directory this tree knows.
    func children(of path: String) -> [Node]? {
        let key = Self.key(path)
        if !key.isEmpty, nodes[key]?.isDirectory != true { return nil }
        return (childPaths[key] ?? []).compactMap { nodes[$0] }
    }

    /// Every directory that has to exist for the archive to be walkable. Parents
    /// before children, so creating them in order never needs an intermediate.
    var directoryPaths: [String] {
        nodes.values.filter { $0.isDirectory && !$0.isPackage && $0.isExtractable }
            .map(\.path).sorted { $0.count < $1.count }
    }

    /// Materialized at mount rather than on demand: containment is judged from
    /// the real link on disk, so an escaping link has to be there before any
    /// row claims to be readable.
    var symbolicLinkMembers: [String] {
        nodes.values.filter { $0.kind == .symbolicLink && $0.isExtractable }.map(\.member).sorted()
    }

    /// Entries that can be listed but never extracted, with the reason.
    var inertPaths: [String] {
        nodes.values.filter { !$0.isExtractable }.map(\.path).sorted()
    }

    var isEmpty: Bool { nodes.isEmpty }
    var count: Int { nodes.count }

    /// What to extract to make one directory's own listing complete: its files,
    /// and any package among its children, which must come whole.
    /// Sub-directories need nothing — the skeleton already holds them.
    func materializationPlan(for path: String) -> (leaves: [String], packages: [String]) {
        guard let children = children(of: path) else { return ([], []) }
        var leaves: [String] = []
        var packages: [String] = []
        for child in children where child.isExtractable {
            if child.isPackage { packages.append(child.member) }
            else if child.kind == .file { leaves.append(child.member) }
        }
        return (leaves, packages)
    }

    // MARK: - Construction rules

    struct NormalizedName {
        let components: [String]
        let escapesRoot: Bool
    }

    /// bsdtar's own rewrites, reproduced so a row resolves to the path
    /// extraction will really write: a leading `/` is removed, an `X:` drive
    /// prefix is removed, `.` components are dropped and repeated separators
    /// collapse. All measured against bsdtar itself.
    static func normalize(_ raw: String) -> NormalizedName? {
        var text = raw
        // `C:/win.txt` extracts to `win.txt`: the whole drive prefix goes.
        if text.count >= 2 {
            let characters = Array(text)
            if characters[1] == ":", characters[0].isLetter {
                text = String(characters.dropFirst(2))
            }
        }
        var escapes = false
        var components: [String] = []
        for piece in text.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(piece)
            if component == "." { continue }
            if component == ".." { escapes = true; continue }
            components.append(component)
        }
        guard !components.isEmpty else { return nil }
        return NormalizedName(components: components, escapesRoot: escapes)
    }

    /// A name the listing itself had to escape cannot be addressed back to
    /// bsdtar: a control character comes through as `\t`, and the escaped
    /// spelling does not match on extraction. For ZIP this test is exact —
    /// libarchive folds a literal backslash in an entry name to `/`, so a
    /// backslash surviving into a listing is always an escape.
    static func isAddressable(_ raw: String) -> Bool { !raw.contains("\\") }

    /// Escaping is mandatory: unescaped `star*.txt` takes three files, escaped
    /// takes one (measured). Over-escaping is harmless.
    static func escapeMember(_ raw: String) -> String {
        var escaped = ""
        for character in raw {
            if character == "\\" || character == "*" || character == "?"
                || character == "[" || character == "]" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// `UTType(filenameExtension:)` alone answers `.app` with
    /// `com.apple.application-file`, which is **not** a package; conforming the
    /// lookup to `.directory` gives `com.apple.application-bundle`, which is,
    /// and matches the real `isPackageKey` on every fixture tried.
    static func isPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        if let cached = packageCache.value(for: ext) { return cached }
        let type = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: .directory)
            .first { !$0.isDynamic }
        let result = type?.conforms(to: .package) ?? false
        packageCache.store(result, for: ext)
        return result
    }

    private static let packageCache = ExtensionCache()

    /// `UTType` lookups are not free and an archive repeats extensions heavily.
    private final class ExtensionCache {
        private let lock = NSLock()
        private var storage: [String: Bool] = [:]
        func value(for ext: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }; return storage[ext.lowercased()]
        }
        func store(_ value: Bool, for ext: String) {
            lock.lock(); defer { lock.unlock() }; storage[ext.lowercased()] = value
        }
    }

    // MARK: - Helpers

    private static func key(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private static func parent(of path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return "" }
        components.removeLast()
        return components.joined(separator: "/")
    }

    private static func synthesizeAncestors(of components: [String],
                                            into nodes: inout [String: Node],
                                            order: inout [String]) {
        guard components.count > 1 else { return }
        var prefix: [String] = []
        for component in components.dropLast() {
            prefix.append(component)
            let path = prefix.joined(separator: "/")
            guard nodes[path] == nil else { continue }
            order.append(path)
            nodes[path] = Node(name: component, path: path, member: escapeMember(path),
                               kind: .directory, uncompressedSize: 0,
                               isPackage: isPackage(path), isExtractable: true, childCount: 0)
        }
    }

    private static func marked(_ node: Node, package: Bool? = nil, childCount: Int? = nil) -> Node {
        Node(name: node.name, path: node.path, member: node.member, kind: node.kind,
             uncompressedSize: node.uncompressedSize, isPackage: package ?? node.isPackage,
             isExtractable: node.isExtractable, childCount: childCount ?? node.childCount)
    }
}
