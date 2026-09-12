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
        if !itemExists(first) { return first }
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) copy \(n)" : "\(base) copy \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !itemExists(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: - Instant operations

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
    static func trash(_ urls: [URL]) throws -> [(original: URL, trashed: URL)] {
        var out: [(URL, URL)] = []
        for url in urls {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let r = result as URL? { out.append((url, r)) }
        }
        return out
    }

    static func delete(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.removeItem(at: url) }
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
                         progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                         task suppliedTask: TransferTask? = nil,
                         options: TransferOptions = .init(),
                         asyncConflict: AsyncConflictHandler? = nil,
                         completion: @escaping (TransferResult) -> Void) -> TransferTask {
        let task = suppliedTask ?? TransferTask(sources: urls, destination: directory, kind: kind)
        let engine = TransferEngine(task: task, options: options, conflict: conflict, asyncConflict: asyncConflict, progress: progress)
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

    // MARK: - Standard conflict dialog (Finder's, rebuilt — macOS has no public one)

    private static func describe(_ url: URL) -> (date: Date?, size: Int64, isDir: Bool) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isPackageKey])
        return (v?.contentModificationDate, Int64(v?.fileSize ?? 0), (v?.isDirectory ?? false) && !(v?.isPackage ?? false))
    }

    /// One alert per conflict; "Apply to all" appears when more are coming.
    static func askConflict(in window: NSWindow?, _ c: Conflict) -> ConflictDecision {
        if SmokeTest.isRequested { return ConflictDecision(resolution: .cancel) }
        let verb = c.kind == .move ? "moving" : "copying"
        let name = c.destination.lastPathComponent
        let existing = describe(c.destination), incoming = describe(c.source)
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let age: String
        switch (incoming.date, existing.date) {
        case let (i?, e?) where i > e: age = "The item you’re \(verb) is newer."
        case let (i?, e?) where i < e: age = "The item you’re \(verb) is older."
        default: age = incoming.size == existing.size ? "Both items were modified at the same time." : ""
        }
        func line(_ what: String, _ d: (date: Date?, size: Int64, isDir: Bool)) -> String {
            let when = d.date.map { f.string(from: $0) } ?? "unknown date"
            return d.isDir ? "\(what): folder, modified \(when)" : "\(what): \(ByteCountFormatter.string(fromByteCount: d.size, countStyle: .file)), modified \(when)"
        }

        let alert = NSAlert()
        alert.messageText = c.bothFolders
            ? "A folder named “\(name)” already exists in this location. Do you want to replace it with the one you’re \(verb), or merge them?"
            : "An item named “\(name)” already exists in this location. Do you want to replace it with the one you’re \(verb)?"
        alert.informativeText = [age, line("Existing", existing), line(c.kind == .move ? "Moving" : "Copying", incoming)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        alert.addButton(withTitle: "Keep Both")                       // default: never destructive
        if c.bothFolders { alert.addButton(withTitle: "Merge") }
        if c.remaining > 1 { alert.addButton(withTitle: "Skip") }
        alert.addButton(withTitle: "Stop")
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        if c.remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all (\(c.remaining) items)"
        }
        let response = alert.runModal()
        let clicked = alert.buttons.first { $0.tag == response.rawValue }?.title ?? "Stop"
        let resolution: ConflictResolution
        switch clicked {
        case "Keep Both": resolution = .keepBoth
        case "Merge":     resolution = .merge
        case "Skip":      resolution = .skip
        case "Replace":   resolution = .replace
        default:          resolution = .cancel
        }
        return ConflictDecision(resolution: resolution,
                                applyToAll: c.remaining > 1 && alert.suppressionButton?.state == .on && resolution != .cancel)
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
