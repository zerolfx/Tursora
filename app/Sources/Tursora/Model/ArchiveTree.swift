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
        /// rewrites and the volume's own folding: the spelling a row shows and
        /// the spelling its published file has. Empty for the root itself.
        /// On a case-insensitive volume `d/two.txt` lands in the `D` that
        /// `D/one.txt` created, so its path is `D/two.txt` (measured).
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
        /// The owner's execute bit, for a file. Decides its Kind (D97).
        let isExecutable: Bool
        /// A bundle, decided by extension. It has to be extracted whole or the
        /// application or document it represents is broken.
        let isPackage: Bool
        /// Why this entry must never be asked for, or nil when it can be. It is
        /// never put in a batch: bsdtar would refuse it, and for an encrypted
        /// member it would leave a zero-filled file behind while doing so.
        /// Nor is it listed (`listedChildren`): encrypted content is not
        /// supported, and a `..` or unaddressable name has no row to open.
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

        /// Why a copy of the folder holding it goes without it.
        var explanation: String {
            switch self {
            case .parentTraversal: return "Its name would place it outside the archive."
            case .unaddressable: return "Its name cannot be read back from the archive."
            case .encrypted: return "It is password-protected."
            }
        }
    }

    /// Where a path leads once every symbolic link along it is followed.
    enum LinkResolution: Equatable {
        /// To this entry's path; the empty path is the archive's root.
        case inside(String)
        /// Out of the archive: an absolute target, or `..` above the root.
        case escapes
        /// To nothing the archive holds, or through something that is not a
        /// folder.
        case dangling
        /// More hops than the kernel itself will follow.
        case loop
    }

    /// `MAXSYMLINKS` on macOS: past this many links in one lookup the kernel
    /// answers ELOOP, so the tree gives up at the same point.
    static let maximumLinkHops = 32

    /// Keyed by the folded path — the path as the volume compares it — so a
    /// lookup in any spelling the volume would accept finds the entry.
    private var nodes: [String: Node] = [:]
    private var childPaths: [String: [String]] = [:]

    /// An earlier entry that a later one replaced under a spelling of its
    /// own, such as `A.txt` before `a.txt`. It has no row, but bsdtar still
    /// knows it by that spelling: a selection has to exclude it by name, or
    /// its bytes land first and its line reads as unplaced.
    private struct Shadow {
        let key: String
        let raw: String
        let member: String
        let kind: ArchiveEntrySummary.Kind
    }
    private var shadowed: [Shadow] = []

    /// Whether names are compared the way a case-insensitive volume compares
    /// them. Unicode normalization needs no flag: libarchive hands every name
    /// over in NFD on macOS, and Swift compares strings by canonical
    /// equivalence (both measured).
    let isCaseInsensitive: Bool

    init(entries: [ArchiveEntrySummary], modificationDates: [String: Date]) {
        self.init(entries: entries, records: modificationDates.mapValues {
            ZIPCentralDirectory.Record(modificationDate: $0)
        })
    }

    init(entries: [ArchiveEntrySummary], records: [String: ZIPCentralDirectory.Record] = [:],
         caseInsensitive: Bool = false) {
        isCaseInsensitive = caseInsensitive
        // Two passes: place every real entry first, so a file always beats a
        // directory implied by some other entry's path, then index children.
        var order: [String] = []
        var synthesized = Set<String>()
        for entry in entries {
            guard let normalized = Self.normalize(entry.name) else { continue }
            let rawPath = normalized.components.joined(separator: "/")
            // Folding is per character, so the folded path splits into the
            // folded components and every ancestor's key is one of its prefixes.
            let folded = fold(rawPath).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard folded.count == normalized.components.count else { continue }
            // Each ancestor is placed under the spelling its parent is shown
            // with, which is where the volume puts it.
            var parentPath = "", parentKey = ""
            for index in normalized.components.indices.dropLast() {
                let component = normalized.components[index]
                let key = parentKey.isEmpty ? folded[index] : parentKey + "/" + folded[index]
                if let existing = nodes[key] {
                    parentPath = existing.path
                } else {
                    let path = parentPath.isEmpty ? component : parentPath + "/" + component
                    let raw = normalized.components[...index].joined(separator: "/")
                    nodes[key] = Node(name: component, path: path, member: Self.escapeMember(raw), rawName: raw,
                                      kind: .directory, uncompressedSize: 0, isExecutable: false,
                                      isPackage: Self.isPackage(path), inertReason: nil, insidePackage: false,
                                      childCount: 0, modificationDate: nil)
                    synthesized.insert(key)
                    order.append(key)
                    parentPath = path
                }
                parentKey = key
            }
            let name = normalized.components[normalized.components.count - 1]
            let key = parentKey.isEmpty ? folded[folded.count - 1] : parentKey + "/" + folded[folded.count - 1]
            let existing = nodes[key]
            // A directory keeps the first spelling it was created with: a
            // later `d/` record lands in the existing `D` (measured). A file
            // takes the last: extraction replaces the earlier file, name and
            // bytes both (measured).
            let keepsSpelling = entry.kind == .directory && existing?.isDirectory == true
            let path = keepsSpelling ? existing!.path : (parentPath.isEmpty ? name : parentPath + "/" + name)
            let record = records[rawPath]
            let reason: InertReason? = normalized.escapesRoot ? .parentTraversal
                : !Self.isAddressable(entry.name) ? .unaddressable
                : record?.isEncrypted == true ? .encrypted
                : nil
            // Only a spelling bsdtar tells apart needs remembering: it treats
            // a leading `./` or `/` and repeated separators as the same name,
            // so an exclusion of `./a.txt` would take `a.txt` with it.
            if let existing, !synthesized.contains(key),
               Self.normalize(existing.rawName)?.components.joined(separator: "/") != rawPath {
                shadowed.append(Shadow(key: key, raw: existing.rawName, member: existing.member, kind: existing.kind))
            }
            let node = Node(name: keepsSpelling ? existing!.name : name,
                            path: path,
                            member: Self.escapeMember(entry.name),
                            rawName: entry.name,
                            kind: entry.kind,
                            uncompressedSize: entry.uncompressedSize,
                            isExecutable: entry.kind == .file && entry.isExecutable,
                            isPackage: entry.kind == .directory && Self.isPackage(path),
                            inertReason: reason,
                            insidePackage: false,
                            childCount: 0,
                            modificationDate: record?.modificationDate)
            // Last wins: two entries of one name in a ZIP are legal, and
            // extraction yields the later one's content (measured).
            if existing == nil { order.append(key) }
            synthesized.remove(key)
            nodes[key] = node
        }
        // Package status is decided per path by extension, so `Demo.app` is a
        // package and `Demo.app/Contents` is not. Without this, the skeleton
        // created `Demo.app/Contents` and so the package's empty shell, and a
        // package that is not yet extracted already existed on disk.
        for key in order {
            var ancestor = Self.parent(of: key)
            while !ancestor.isEmpty {
                if nodes[ancestor]?.isPackage == true {
                    nodes[key] = Self.marked(nodes[key]!, insidePackage: true)
                    break
                }
                ancestor = Self.parent(of: ancestor)
            }
        }
        var counts: [String: Int] = [:]
        for key in order {
            let parent = Self.parent(of: key)
            childPaths[parent, default: []].append(key)
            counts[parent, default: 0] += 1
        }
        for (key, count) in counts where nodes[key] != nil {
            nodes[key] = Self.marked(nodes[key]!, childCount: count)
        }
    }

    // MARK: - Queries

    func node(at path: String) -> Node? { nodes[key(path)] }

    /// Direct children, or nil when the path is not a directory this tree knows.
    func children(of path: String) -> [Node]? {
        let key = key(path)
        if !key.isEmpty, nodes[key]?.isDirectory != true { return nil }
        return (childPaths[key] ?? []).compactMap { nodes[$0] }
    }

    /// The rows a folder shows: its children that can be extracted. An
    /// encrypted member is not supported (D94), and a `..` or unaddressable
    /// name has nothing to open, so none of them is listed.
    func listedChildren(of path: String) -> [Node]? {
        children(of: path)?.filter(\.isExtractable)
    }

    /// Follows every symbolic link along a path, lexically, the way the kernel
    /// would on disk: `..` after a link climbs from where the link leads, an
    /// absolute target leaves the archive, and more than `maximumLinkHops`
    /// links is a loop. Passing through a package is allowed — its entries
    /// are in the tree whether or not it is extracted yet. `readLink` returns a
    /// link's target, read from the link bsdtar wrote at mount; nil when that
    /// link is not on disk.
    func resolve(_ path: String, readLink: (String) -> String?) -> LinkResolution {
        var pending = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var resolved: [String] = []
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else { return .escapes }
                resolved.removeLast()
                continue
            }
            guard let node = node(at: (resolved + [component]).joined(separator: "/")) else { return .dangling }
            if node.kind == .symbolicLink {
                hops += 1
                guard hops <= Self.maximumLinkHops else { return .loop }
                guard node.isExtractable, let target = readLink(node.path), !target.isEmpty else { return .dangling }
                if target.hasPrefix("/") { return .escapes }
                pending = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init) + pending
                continue
            }
            if !pending.isEmpty, !node.isDirectory { return .dangling }
            resolved = node.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        return .inside(resolved.joined(separator: "/"))
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
        let prefix = key(package) + "/"
        return nodes.filter { $0.key.hasPrefix(prefix) && !$0.value.isExtractable }.map(\.value.member).sorted()
    }

    /// Entries that can be listed but never extracted, with the reason.
    var inertPaths: [String] {
        nodes.values.filter { !$0.isExtractable }.map(\.path).sorted()
    }

    var isEmpty: Bool { nodes.isEmpty }
    var count: Int { nodes.count }

    func forEachNode(_ body: (Node) -> Void) { nodes.values.forEach(body) }

    /// Everything below a folder, for reporting what a copy of it goes
    /// without.
    func descendants(of directory: String) -> [Node] {
        let scope = key(directory)
        let prefix = scope.isEmpty ? "" : scope + "/"
        return nodes.filter { scope.isEmpty || $0.key.hasPrefix(prefix) }.map(\.value)
    }

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
        let key = key(path)
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
    /// as lines the verdict cannot place; a directory record a later spelling
    /// replaced still announces itself, under the directory it landed in.
    func spellings(within directory: String, recursive: Bool) -> [ArchiveMemberSpelling] {
        let scope = key(directory)
        let prefix = scope.isEmpty ? "" : scope + "/"
        func inScope(_ key: String) -> Bool {
            guard scope.isEmpty || key.hasPrefix(prefix) else { return false }
            return recursive || !key.dropFirst(prefix.count).contains("/")
        }
        var result = nodes.filter { inScope($0.key) }.map { spelling(of: $0.value) }
        for shadow in shadowed where shadow.kind == .directory && inScope(shadow.key) {
            guard let winner = nodes[shadow.key] else { continue }
            result.append(ArchiveMemberSpelling(path: winner.path, raw: shadow.raw, escaped: shadow.member))
        }
        return result
    }

    /// A package and every entry inside it, each spelled as bsdtar will name it
    /// and all attributed to the package, so its log lines match exactly.
    func packageSpellings(_ package: String) -> [ArchiveMemberSpelling] {
        let key = key(package)
        guard let node = nodes[key] else { return [] }
        let prefix = key + "/"
        return nodes.filter { $0.key == key || $0.key.hasPrefix(prefix) }
            .map { ArchiveMemberSpelling(path: node.path, raw: $0.value.rawName, escaped: $0.value.member) }
            + shadowed.filter { $0.key == key || $0.key.hasPrefix(prefix) }
            .map { ArchiveMemberSpelling(path: node.path, raw: $0.raw, escaped: $0.member) }
    }

    /// What to hand bsdtar to extract a package whole: the package itself,
    /// plus any member inside it spelled differently from the package — on a
    /// case-insensitive volume `demo.app/x` lands in `Demo.app`, but matching
    /// is case-sensitive, so `Demo.app` alone would leave it out (measured).
    func packageMembers(_ package: String) -> [String] {
        let key = key(package)
        guard let node = nodes[key] else { return [] }
        let prefix = key + "/"
        let rawPrefix = (Self.normalize(node.rawName)?.components.joined(separator: "/") ?? node.path) + "/"
        let strays = nodes.filter { $0.key.hasPrefix(prefix) }.map { ($0.value.rawName, $0.value.member) }
            + shadowed.filter { $0.key.hasPrefix(prefix) }.map { ($0.raw, $0.member) }
        return [node.member] + strays.filter { raw, _ in
            !((Self.normalize(raw)?.components.joined(separator: "/") ?? raw) + "/").hasPrefix(rawPrefix)
        }.map(\.1).sorted()
    }

    /// Everything a package holds, for sizing a request before it runs.
    func packageBytes(_ path: String) -> Int64 {
        let prefix = key(path) + "/"
        return nodes.filter { $0.value.kind == .file && $0.key.hasPrefix(prefix) }
            .reduce(Int64(0)) { $0 + $1.value.uncompressedSize }
    }

    /// Earlier files a later spelling replaced, within a folder: excluded by
    /// name from its selection, which would otherwise write them first and
    /// announce them in a line nothing claims. Matching is case-sensitive, so
    /// excluding `c/A.txt` leaves `c/a.txt` alone (measured).
    private func shadowedFiles(under directory: String, recursive: Bool) -> [String] {
        let scope = key(directory)
        let prefix = scope.isEmpty ? "" : scope + "/"
        return shadowed.filter { shadow in
            guard shadow.kind != .directory, scope.isEmpty || shadow.key.hasPrefix(prefix) else { return false }
            return recursive || !shadow.key.dropFirst(prefix.count).contains("/")
        }.map(\.member)
    }

    /// A member bsdtar will not match through a directory include: measured,
    /// include `big` takes `./big/x`, `big//x` and `big/[x]`, but not `/big/x`
    /// or `C:/big/x` — nor `d/x` for a folder shown as `D`, since matching is
    /// case-sensitive while the volume is not. Such a member is always asked
    /// for by name.
    private static func isIrregular(_ node: Node) -> Bool {
        let raw = node.rawName
        if raw.hasPrefix("/") { return true }
        let characters = Array(raw)
        if characters.count >= 2 && characters[1] == ":" && characters[0].isLetter { return true }
        return normalize(raw)?.components.joined(separator: "/") != node.path
    }

    /// The include that selects a folder: its shown spelling, escaped, or none
    /// for the root.
    private func include(for directory: String) -> String? {
        let key = key(directory)
        guard !key.isEmpty, let node = nodes[key] else { return nil }
        return Self.escapeMember(node.path)
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
            excludes += shadowedFiles(under: directory, recursive: false)
            plan.selection = ArchiveTool.directSelection(of: include(for: directory), excluding: excludes)
        }
        return plan
    }

    /// A folder and everything below it, for copying or dragging it out whole.
    /// Its subfolders are already in the skeleton; this fills them.
    func subtreePlan(for directory: String, skipping published: Set<String> = []) -> BatchPlan {
        let scope = key(directory)
        var plan = BatchPlan()
        if let node = nodes[scope], node.isPackage {
            guard node.isExtractable, !published.contains(node.path) else { return plan }
            plan.packages = [spelling(of: node)]
            plan.packageExcludes = inertMembers(inside: scope)
            plan.bytes = packageBytes(scope)
            return plan
        }
        guard scope.isEmpty || nodes[scope]?.isDirectory == true else { return plan }
        let prefix = scope.isEmpty ? "" : scope + "/"
        var excludes: [String] = []
        for (key, node) in nodes where scope.isEmpty || key.hasPrefix(prefix) {
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
        excludes += shadowedFiles(under: directory, recursive: true)
        if !plan.selected.isEmpty {
            plan.selection = ArchiveTool.DirectorySelection(include: include(for: directory), excludes: excludes.sorted())
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
            let key = key(path)
            guard seen.insert(key).inserted, let node = nodes[key], isReachable(key),
                  !published.contains(node.path) else { continue }
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
                    .map(\.member) + shadowedFiles(under: folder, recursive: false)
                let regular = group.filter { !Self.isIrregular($0) }
                plan.leaves += group.filter(Self.isIrregular).map(spelling(of:))
                plan.selected = regular.map(spelling(of:))
                plan.selection = ArchiveTool.directSelection(of: include(for: folder), excluding: excluded)
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

    /// A path as the volume compares it. APFS folds case with full Unicode
    /// case folding — `ß` meets `ss`, `ς` meets `σ`, `ﬁ` meets `fi` — which is
    /// what `.caseInsensitive` folding does and `lowercased()` does not
    /// (measured on eleven pairs).
    private func fold(_ path: String) -> String {
        guard isCaseInsensitive else { return path }
        if path.utf8.allSatisfy({ $0 < 0x80 }) { return path.lowercased() }
        return path.folding(options: .caseInsensitive, locale: nil)
    }

    private func key(_ path: String) -> String {
        fold(path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/"))
    }

    private static func parent(of path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return "" }
        components.removeLast()
        return components.joined(separator: "/")
    }

    private static func marked(_ node: Node, insidePackage: Bool? = nil, childCount: Int? = nil) -> Node {
        Node(name: node.name, path: node.path, member: node.member, rawName: node.rawName, kind: node.kind,
             uncompressedSize: node.uncompressedSize, isExecutable: node.isExecutable, isPackage: node.isPackage,
             inertReason: node.inertReason, insidePackage: insidePackage ?? node.insidePackage,
             childCount: childCount ?? node.childCount, modificationDate: node.modificationDate)
    }
}
