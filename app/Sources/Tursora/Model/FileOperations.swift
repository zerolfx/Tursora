import AppKit
import Darwin

/// Filesystem mutations. Trash and rename remain synchronous system operations;
/// copy/move use controlled background tasks and report back on main.
/// Conflicts are resolved by a handler the UI supplies, called on the main
/// thread so it can show a sheet.
enum FileOperations {

    enum Kind { case copy, move }
    enum ConflictResolution { case replace, keepBoth, skip, merge, cancel }

    /// What the UI learned when it asked: the choice, and whether it should
    /// silently apply to the remaining conflicts of this batch (Finder's
    /// "Apply to all" checkbox).
    struct ConflictDecision {
        var resolution: ConflictResolution
        var applyToAll = false
    }

    struct Conflict {
        struct Info {
            let date: Date?
            let size: Int64
            let isDirectory: Bool
        }
        let source: URL
        let destination: URL
        let kind: Kind
        let remaining: Int
        let sourceInfo: Info
        let destinationInfo: Info
        var bothFolders: Bool { sourceInfo.isDirectory && destinationInfo.isDirectory }
        init(source: URL, destination: URL, kind: Kind, remaining: Int) {
            self.source = source; self.destination = destination; self.kind = kind; self.remaining = remaining
            func info(_ url: URL) -> Info {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
                return Info(date: values?.contentModificationDate, size: Int64(values?.fileSize ?? 0),
                            isDirectory: values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true)
            }
            sourceInfo = info(source); destinationInfo = info(destination)
        }
    }

    typealias ConflictHandler = (Conflict) -> ConflictDecision
    typealias AsyncConflictHandler = (Conflict, @escaping (ConflictDecision) -> Void) -> Void

    struct Failure {
        let url: URL
        let error: Error
    }

    struct TransferResult {
        var created: [URL] = []
        /// (original, new) pairs for moves — what undo needs.
        var moved: [(from: URL, to: URL)] = []
        var failures: [Failure] = []
        var cancelled = false
        var journal: TransferJournal?
    }

    // MARK: - Naming

    /// "Report.pdf" → "Report 2.pdf", "Report 3.pdf", … until free.
    static func uniqueURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !itemExists(candidate) { return candidate }
            n += 1
        }
    }

    /// Finder's duplicate naming: "Report.pdf" → "Report copy.pdf" → "Report copy 2.pdf".
    static func duplicateURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let first = dir.appendingPathComponent(ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)")
        return itemExists(first) ? uniqueURL(for: first) : first
    }

    // MARK: - Instant operations

    /// Creates "untitled folder" (or "untitled folder 2", …) inside `directory`.
    static func createFolder(in directory: URL, name: String = "untitled folder") throws -> URL {
        let base = directory.appendingPathComponent(name)
        let url = itemExists(base) ? uniqueURL(for: base) : base
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Moves one item to an exact destination path (undoing a move or trash).
    static func moveItem(at url: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// A selected directory covers descendants only through actual directories.
    /// An intervening symlink leaves its explicitly selected target child outside
    /// the copied/removed tree, even when the link itself was not selected.
    /// FileManager attributes inspect each path's leaf without following a link.
    static func mutationSources(_ urls: [URL]) -> [URL] {
        let paths = urls.map { $0.standardizedFileURL.path }
        let selectedPaths = Set(paths)
        var directoryCache: [String: Bool] = [:]
        func isActualDirectory(_ path: String) -> Bool {
            if let cached = directoryCache[path] { return cached }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let isDirectory = attributes?[.type] as? FileAttributeType == .typeDirectory
            directoryCache[path] = isDirectory
            return isDirectory
        }
        var emitted = Set<String>()
        return zip(urls, paths).compactMap { url, path in
            guard emitted.insert(path).inserted else { return nil }
            var intermediates: [String] = []
            var parent = (path as NSString).deletingLastPathComponent
            while parent != path, !parent.isEmpty {
                intermediates.append(parent)
                if selectedPaths.contains(parent) {
                    // A barrier below the nearest selected ancestor also prevents
                    // any higher selected ancestor from covering this source.
                    return intermediates.allSatisfy(isActualDirectory) ? nil : url
                }
                let next = (parent as NSString).deletingLastPathComponent
                if next == parent { break }
                parent = next
            }
            return url
        }
    }

    /// Rename via the name resource, which — unlike moveItem — handles a
    /// case-only rename on case-insensitive APFS ("Foo" → "foo").
    @discardableResult
    static func rename(_ url: URL, to name: String) throws -> URL {
        var values = URLResourceValues()
        values.name = name
        var target = url
        try target.setResourceValues(values)
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Finder-visible trash with Put Back. Returns (original, trashed) pairs.
    /// While `TrashLocation.userTrashOverride` is set the items move into that
    /// fixture directory instead, so a check can never write into the real
    /// `~/.Trash`; with no override this is `FileManager.trashItem` unchanged.
    static func trash(_ urls: [URL]) throws -> [(original: URL, trashed: URL)] {
        var out: [(URL, URL)] = []
        for url in mutationSources(urls) {
            if let fixture = TrashLocation.userTrashOverride {
                let base = fixture.appendingPathComponent(url.lastPathComponent)
                let destination = itemExists(base) ? uniqueURL(for: base) : base
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                out.append((url, destination))
                continue
            }
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let r = result as URL? { out.append((url, r)) }
        }
        return out
    }

    static func delete(_ urls: [URL]) throws {
        for url in mutationSources(urls) { try FileManager.default.removeItem(at: url) }
    }

    /// Finder's drop rule, shared by the list, grid, sidebar, folder tree, tab
    /// strip and breadcrumb: ⌥ forces a copy, ⌘ forces a move even across
    /// volumes, otherwise the same volume moves and another volume copies; a
    /// drop onto an item's own folder or onto itself does nothing.
    ///
    /// AppKit narrows the drag source's mask by the held modifier, so the
    /// modifiers arrive here as the mask itself: `.copy` for ⌥ and `.generic`
    /// for ⌘ (see `DragAndDrop.sourceMask(readOnly:local:)`).
    static func dropOperation(for urls: [URL], into destination: URL, sourceMask: NSDragOperation) -> NSDragOperation {
        guard !urls.isEmpty else { return [] }
        if urls.contains(where: { $0.standardizedFileURL == destination.standardizedFileURL }) { return [] }
        let alreadyThere = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL }
        if sourceMask == .copy { return .copy }
        if alreadyThere { return [] }
        if sourceMask == .generic { return .move }      // ⌘ moves, whatever the volumes
        return sameVolume(urls[0], destination) ? .move : .copy
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: ka).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: ka).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    // MARK: - Copy / move

    /// Starts a task with fixed URLs; the worker owns mutation until completion.
    /// Existing synchronous conflict handlers remain available for model callers;
    /// the application supplies asyncConflict to keep its controls responsive.
    @discardableResult
    static func transfer(_ urls: [URL], to directory: URL, kind: Kind,
                         conflict: @escaping ConflictHandler,
                         task suppliedTask: TransferTask? = nil,
                         options: TransferOptions = .init(),
                         asyncConflict: AsyncConflictHandler? = nil,
                         completion: @escaping (TransferResult) -> Void) -> TransferTask {
        let task = suppliedTask ?? TransferTask(sources: urls, destination: directory, kind: kind)
        let engine = TransferEngine(task: task, options: options, conflict: conflict, asyncConflict: asyncConflict)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = engine.run()
            DispatchQueue.main.async { completion(result) }
        }
        return task
    }

    /// Replay uses exclusive same-volume renames only, so NSUndoManager can
    /// register its inverse while isUndoing/isRedoing is still true.
    static func replay(_ journal: TransferJournal) throws -> TransferJournal { try journal.replay() }

    /// fileExists follows links and misses a dangling symlink conflict.
    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func report(_ failures: [Failure], in window: NSWindow?) {
        guard !failures.isEmpty else { return }
        if SmokeTest.isRequested {
            failures.forEach { print("File operation failed: \($0.url.lastPathComponent): \($0.error.localizedDescription)") }
            return
        }
        let alert = NSAlert()
        alert.messageText = failures.count == 1
            ? "“\(failures[0].url.lastPathComponent)” couldn’t be processed."
            : "\(failures.count) items couldn’t be processed."
        alert.informativeText = failures.map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
            .prefix(5).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.runModal()
    }
}
