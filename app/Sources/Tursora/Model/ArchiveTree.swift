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
        /// The archive's own spelling, unescaped. What bsdtar names in a log
        /// line, and how a member whose spelling bsdtar rewrites is recognised.
        let rawName: String
        let kind: ArchiveEntrySummary.Kind
        let uncompressedSize: Int64
        /// A bundle, decided by extension. It has to be extracted whole or the
        /// application or document it represents is broken.
        let isPackage: Bool
        /// Why this entry must never be asked for, or nil when it can be. It is
        /// never put in a batch: bsdtar would refuse it, and for an encrypted
        /// member it would leave a zero-filled file behind while doing so.
        /// Whether such an entry is *shown* is the listing's decision, not the
        /// tree's — at this stage the listing reads the disk, where an inert
        /// entry never lands, so it is not shown.
        let inertReason: InertReason?
        /// Somewhere inside a package. Such an entry arrives with its package in
        /// one piece and is never created on its own — not in the skeleton, and
        /// not as a mount-time link — or the package would already exist as an
        /// empty shell before it was ever extracted.
        let insidePackage: Bool
        /// Direct children, for seeding the item count of a directory whose
        /// contents are not on disk yet.
        let childCount: Int
        /// From the central directory, joined by path (Stage 3). Nil for a
        /// directory the archive never recorded — it was synthesized from its
        /// children's paths and has no date of its own to show — and for any
        /// entry the join missed.
        let modificationDate: Date?

        var isDirectory: Bool { kind == .directory }
        var isExtractable: Bool { inertReason == nil }
    }

    enum InertReason: Equatable {
        /// A `..` component: bsdtar refuses it outright.
        case parentTraversal
        /// A name the listing had to escape, such as a control character, whose
        /// escaped spelling no longer matches on extraction.
        case unaddressable
        /// Password-protected (D94). Extraction with the random passphrase the
        /// app supplies fails, leaving a correctly-sized file of zeros.
        case encrypted
    }

    private var nodes: [String: Node] = [:]
    private var childPaths: [String: [String]] = [:]

    init(entries: [ArchiveEntrySummary], modificationDates: [String: Date]) {
        self.init(entries: entries, records: modificationDates.mapValues {
            ZIPCentralDirectory.Record(modificationDate: $0)
        })
    }

    init(entries: [ArchiveEntrySummary], records: [String: ZIPCentralDirectory.Record] = [:]) {
        // Two passes: place every real entry first, so a file always beats a
        // directory implied by some other entry's path, then index children.
        var order: [String] = []
        for entry in entries {
            guard let normalized = Self.normalize(entry.name) else { continue }
            Self.synthesizeAncestors(of: normalized.components, into: &nodes, order: &order)
            let path = normalized.components.joined(separator: "/")
            guard !path.isEmpty else { continue }
            let record = records[path]
            let reason: InertReason? = normalized.escapesRoot ? .parentTraversal
                : !Self.isAddressable(entry.name) ? .unaddressable
                : record?.isEncrypted == true ? .encrypted
                : nil
            let node = Node(name: normalized.components.last ?? entry.name,
                            path: path,
                            member: Self.escapeMember(entry.name),
                            rawName: entry.name,
                            kind: entry.kind,
                            uncompressedSize: entry.uncompressedSize,
                            isPackage: entry.kind == .directory && Self.isPackage(path),
                            inertReason: reason,
                            insidePackage: false,
                            childCount: 0,
                            modificationDate: record?.modificationDate)
            // Last wins: two entries of one name in a ZIP are legal, and
            // extraction yields the later one's content (measured).
            if nodes[path] == nil { order.append(path) }
            nodes[path] = node
        }
        // A directory synthesized from some path may also be a package.
        for path in order where nodes[path]?.kind == .directory && nodes[path]?.isPackage == false {
            if Self.isPackage(path) { nodes[path] = Self.marked(nodes[path]!, package: true) }
        }
        // Package status is decided per path by extension, so `Demo.app` is a
        // package and `Demo.app/Contents` is not. Without this, the skeleton
        // created `Demo.app/Contents` and so the package's empty shell, and a
        // package that is not yet extracted already existed on disk.
        for path in order {
            var ancestor = Self.parent(of: path)
            while !ancestor.isEmpty {
                if nodes[ancestor]?.isPackage == true {
                    nodes[path] = Self.marked(nodes[path]!, insidePackage: true)
                    break
                }
                ancestor = Self.parent(of: ancestor)
            }
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
        nodes.values.filter { $0.isDirectory && !$0.isPackage && !$0.insidePackage && $0.isExtractable }
            .map(\.path).sorted { $0.count < $1.count }
    }

    /// Materialized at mount rather than on demand: containment is judged from
    /// the real link on disk, so an escaping link has to be there before any
    /// row claims to be readable.
    var symbolicLinkMembers: [String] {
        nodes.values.filter { $0.kind == .symbolicLink && !$0.insidePackage && $0.isExtractable }
            .map(\.member).sorted()
    }

    /// Members inside a package that must be left out when the package is
    /// extracted whole — an encrypted file inside an otherwise ordinary app
    /// would otherwise arrive as zeros.
    func inertMembers(inside package: String) -> [String] {
        let prefix = Self.key(package) + "/"
        return nodes.values.filter { $0.path.hasPrefix(prefix) && !$0.isExtractable }.map(\.member).sorted()
    }

    /// Entries that can be listed but never extracted, with the reason.
    var inertPaths: [String] {
        nodes.values.filter { !$0.isExtractable }.map(\.path).sorted()
    }

    var isEmpty: Bool { nodes.isEmpty }
    var count: Int { nodes.count }

    // MARK: - Stage 2 batch plans

    /// Everything one batch will ask bsdtar for, in at most three runs: leaves
    /// one by one with `-n`, packages whole, and one directory selection.
    struct BatchPlan: Equatable {
        var leaves: [ArchiveMemberSpelling] = []
        var packages: [ArchiveMemberSpelling] = []
        var packageExcludes: [String] = []
        var selection: ArchiveTool.DirectorySelection?
        /// What the selection is expected to write.
        var selected: [ArchiveMemberSpelling] = []
        var bytes: Int64 = 0

        var isEmpty: Bool { leaves.isEmpty && packages.isEmpty && selected.isEmpty }
        /// Every path this batch may publish.
        var publishes: [String] { (leaves + packages + selected).map(\.path) }
    }

    /// Past this many requested files that are also most of their folder, one
    /// directory selection beats a member list: `-T` matching costs about
    /// 14 ns per (archive entry × pattern), so 20,000 names against a 50,000-
    /// entry archive take seconds to match before a byte is written (measured).
    static let selectionThreshold = 256

    func spelling(of node: Node) -> ArchiveMemberSpelling {
        ArchiveMemberSpelling(path: node.path, raw: node.rawName, escaped: node.member)
    }

    /// Whether bytes for this path may be published under the root. Never under
    /// a symbolic link — extracting into empty staging bypasses bsdtar's own
    /// "Cannot extract through symlink" check, so publication must refuse it
    /// itself — and never for something inside a package, which arrives with
    /// its package in one piece.
    func isReachable(_ path: String) -> Bool {
        let key = Self.key(path)
        guard let node = nodes[key], node.isExtractable, !node.insidePackage else { return false }
        var ancestor = Self.parent(of: key)
        while !ancestor.isEmpty {
            guard let parent = nodes[ancestor], parent.isDirectory, !parent.isPackage,
                  parent.kind != .symbolicLink, parent.isExtractable else { return false }
            ancestor = Self.parent(of: ancestor)
        }
        return true
    }

    /// Every entry a selection of this folder may announce — its direct children,
    /// or everything below it — each under its own path. A selection also names
    /// directory records (`x F/`), which are never published but must not read
    /// as lines the verdict cannot place.
    func spellings(within directory: String, recursive: Bool) -> [ArchiveMemberSpelling] {
        let key = Self.key(directory)
        let prefix = key.isEmpty ? "" : key + "/"
        return nodes.values.filter { node in
            guard key.isEmpty || node.path.hasPrefix(prefix) else { return false }
            return recursive || !node.path.dropFirst(prefix.count).contains("/")
        }.map(spelling(of:))
    }

    /// A package and every entry inside it, each spelled as bsdtar will name it
    /// and all attributed to the package, so its log lines match exactly.
    func packageSpellings(_ package: String) -> [ArchiveMemberSpelling] {
        let key = Self.key(package)
        let prefix = key + "/"
        return nodes.values.filter { $0.path == key || $0.path.hasPrefix(prefix) }
            .map { ArchiveMemberSpelling(path: key, raw: $0.rawName, escaped: $0.member) }
    }

    /// Everything a package holds, for sizing a request before it runs.
    func packageBytes(_ path: String) -> Int64 {
        let prefix = Self.key(path) + "/"
        return nodes.values.filter { $0.kind == .file && $0.path.hasPrefix(prefix) }
            .reduce(Int64(0)) { $0 + $1.uncompressedSize }
    }

    /// A member bsdtar will not match through a directory include: measured,
    /// include `big` takes `./big/x`, `big//x` and `big/[x]`, but not `/big/x`
    /// or `C:/big/x`. Such a member is always asked for by name.
    private static func isIrregular(_ node: Node) -> Bool {
        let raw = node.rawName
        if raw.hasPrefix("/") { return true }
        let characters = Array(raw)
        return characters.count >= 2 && characters[1] == ":" && characters[0].isLetter
    }

    /// One folder's direct files, in one directory selection. For prefetching
    /// the folder the user is looking at.
    func prefetchPlan(for directory: String, skipping published: Set<String> = []) -> BatchPlan {
        var plan = BatchPlan()
        guard let children = children(of: directory) else { return plan }
        var excludes: [String] = []
        var skippedCount = 0
        for child in children {
            guard child.isExtractable else { excludes.append(child.member); continue }
            guard !published.contains(child.path) else {
                if child.kind == .file { excludes.append(child.member); skippedCount += 1 }
                continue
            }
            if child.isPackage {
                plan.packages.append(spelling(of: child))
                plan.packageExcludes += inertMembers(inside: child.path)
                plan.bytes += packageBytes(child.path)
            } else if child.kind == .file {
                if Self.isIrregular(child) { plan.leaves.append(spelling(of: child)) }
                else { plan.selected.append(spelling(of: child)) }
                plan.bytes += child.uncompressedSize
            }
        }
        // When most of the folder is already here, naming the rest is cheaper
        // than excluding what is here.
        if !plan.selected.isEmpty, skippedCount > plan.selected.count {
            plan.leaves += plan.selected
            plan.selected = []
        }
        if !plan.selected.isEmpty {
            let include = Self.key(directory).isEmpty ? nil : Self.escapeMember(Self.key(directory))
            plan.selection = ArchiveTool.directSelection(of: include, excluding: excludes)
        }
        return plan
    }

    /// A folder and everything below it, for copying or dragging it out whole.
    /// Its subfolders are already in the skeleton; this fills them.
    func subtreePlan(for directory: String, skipping published: Set<String> = []) -> BatchPlan {
        let key = Self.key(directory)
        var plan = BatchPlan()
        if let node = nodes[key], node.isPackage {
            guard node.isExtractable, !published.contains(key) else { return plan }
            plan.packages = [spelling(of: node)]
            plan.packageExcludes = inertMembers(inside: key)
            plan.bytes = packageBytes(key)
            return plan
        }
        guard key.isEmpty || nodes[key]?.isDirectory == true else { return plan }
        let prefix = key.isEmpty ? "" : key + "/"
        var excludes: [String] = []
        for node in nodes.values where key.isEmpty || node.path.hasPrefix(prefix) {
            guard node.isExtractable else { excludes.append(node.member); continue }
            guard !node.insidePackage, !published.contains(node.path) else { continue }
            if node.isPackage {
                plan.packages.append(spelling(of: node))
                plan.packageExcludes += inertMembers(inside: node.path)
                plan.bytes += packageBytes(node.path)
            } else if node.kind == .file {
                if Self.isIrregular(node) { plan.leaves.append(spelling(of: node)) }
                else { plan.selected.append(spelling(of: node)) }
                plan.bytes += node.uncompressedSize
            }
        }
        // Packages are extracted in their own run; keep them out of this one.
        excludes += plan.packages.map(\.escaped)
        if !plan.selected.isEmpty {
            plan.selection = ArchiveTool.DirectorySelection(include: key.isEmpty ? nil : Self.escapeMember(key),
                                                            excludes: excludes.sorted())
        }
        plan.leaves.sort { $0.path < $1.path }
        plan.packages.sort { $0.path < $1.path }
        plan.selected.sort { $0.path < $1.path }
        return plan
    }

    /// Specific entries, for Open, Copy, Quick Look and the like. Files are
    /// asked for by name; a package comes whole; a folder brings its subtree.
    func batchPlan(for paths: [String], skipping published: Set<String> = []) -> BatchPlan {
        var plan = BatchPlan()
        var seen = Set<String>()
        var fileGroups: [String: [Node]] = [:]
        for path in paths {
            let key = Self.key(path)
            guard seen.insert(key).inserted, let node = nodes[key], isReachable(key),
                  !published.contains(key) else { continue }
            if node.isPackage {
                plan.packages.append(spelling(of: node))
                plan.packageExcludes += inertMembers(inside: key)
                plan.bytes += packageBytes(key)
            } else if node.isDirectory {
                let sub = subtreePlan(for: key, skipping: published)
                plan.leaves += sub.leaves
                plan.packages += sub.packages
                plan.packageExcludes += sub.packageExcludes
                plan.bytes += sub.bytes
                if plan.selection == nil, sub.selection != nil {
                    plan.selection = sub.selection
                    plan.selected = sub.selected
                } else {
                    plan.leaves += sub.selected
                }
            } else if node.kind == .file {
                fileGroups[Self.parent(of: key), default: []].append(node)
                plan.bytes += node.uncompressedSize
            }
        }
        // A large request that is most of one folder becomes that folder's
        // selection; everything else is named.
        let folderFiles: (String) -> Int = { self.children(of: $0)?.filter { $0.kind == .file && $0.isExtractable }.count ?? 0 }
        let best = fileGroups.filter { $0.value.count >= Self.selectionThreshold
                                       && $0.value.count * 2 >= folderFiles($0.key) }
            .max { $0.value.count < $1.value.count }
        for (folder, group) in fileGroups {
            if plan.selection == nil, let best, best.key == folder {
                let requested = Set(group.map(\.path))
                let excluded = (children(of: folder) ?? [])
                    .filter { $0.kind == .file && (!$0.isExtractable || !requested.contains($0.path)) }
                    .map(\.member)
                let regular = group.filter { !Self.isIrregular($0) }
                plan.leaves += group.filter(Self.isIrregular).map(spelling(of:))
                plan.selected = regular.map(spelling(of:))
                plan.selection = ArchiveTool.directSelection(of: folder.isEmpty ? nil : Self.escapeMember(folder),
                                                             excluding: excluded)
            } else {
                plan.leaves += group.map(spelling(of:))
            }
        }
        plan.leaves.sort { $0.path < $1.path }
        return plan
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

    /// The inverse of `escapeMember`, for turning a selection's include back
    /// into the tree path it names.
    static func unescape(_ escaped: String) -> String {
        var result = ""
        var pending = false
        for character in escaped {
            if pending { result.append(character); pending = false }
            else if character == "\\" { pending = true }
            else { result.append(character) }
        }
        return result
    }

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
                               rawName: path, kind: .directory, uncompressedSize: 0,
                               isPackage: isPackage(path), inertReason: nil, insidePackage: false,
                               childCount: 0, modificationDate: nil)
        }
    }

    private static func marked(_ node: Node, package: Bool? = nil, insidePackage: Bool? = nil,
                               childCount: Int? = nil) -> Node {
        Node(name: node.name, path: node.path, member: node.member, rawName: node.rawName, kind: node.kind,
             uncompressedSize: node.uncompressedSize, isPackage: package ?? node.isPackage,
             inertReason: node.inertReason, insidePackage: insidePackage ?? node.insidePackage,
             childCount: childCount ?? node.childCount, modificationDate: node.modificationDate)
    }
}
