import AppKit

/// The file operations behind M5. Trash and rename are synchronous (they are
/// instant); copy/move run on a background queue and report back on main.
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
        let source: URL
        let destination: URL
        let kind: Kind
        /// How many conflicts are still to come in this batch, this one included.
        let remaining: Int
        var bothFolders: Bool {
            let isDir = { (u: URL) in (try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false }
            return isDir(source) && isDir(destination)
        }
    }

    typealias ConflictHandler = (Conflict) -> ConflictDecision

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
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Finder's duplicate naming: "Report.pdf" → "Report copy.pdf" → "Report copy 2.pdf".
    static func duplicateURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let first = dir.appendingPathComponent(ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)")
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) copy \(n)" : "\(base) copy \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
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

    /// Copies or moves `urls` into `directory`. Returns on the main thread.
    /// Conflicts are asked once each on the main thread unless the handler
    /// answered "apply to all"; folder-on-folder can merge recursively.
    static func transfer(_ urls: [URL], to directory: URL, kind: Kind,
                         conflict: @escaping ConflictHandler,
                         progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                         completion: @escaping (TransferResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = TransferResult()
            var policy = BatchPolicy(handler: conflict)
            // Count up front so the dialog can offer "apply to all" only when it matters.
            policy.remaining = urls.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.lastPathComponent).path) }.count
            for (i, src) in urls.enumerated() {
                let dst = directory.appendingPathComponent(src.lastPathComponent)
                transferOne(src, to: dst, kind: kind, policy: &policy, result: &result)
                if result.cancelled { break }
                if let progress { DispatchQueue.main.async { progress(i + 1, urls.count) } }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The batch's memory: the handler, and a decision to reuse once the user
    /// ticked "apply to all".
    private struct BatchPolicy {
        let handler: ConflictHandler
        var remaining = 0
        var applyAll: ConflictResolution?

        mutating func decide(_ c: Conflict) -> ConflictResolution {
            if let applyAll { return applyAll }
            let decision = DispatchQueue.main.sync { handler(c) }
            if decision.applyToAll { applyAll = decision.resolution }
            return decision.resolution
        }
    }

    private static func transferOne(_ src: URL, to dstIn: URL, kind: Kind,
                                    policy: inout BatchPolicy, result: inout TransferResult) {
        let fm = FileManager.default
        var dst = dstIn
        if dst.standardizedFileURL == src.standardizedFileURL {
            // Copying onto itself: Finder makes a "copy"; moving is a no-op.
            if kind == .copy { dst = duplicateURL(for: src) } else { return }
        } else if fm.fileExists(atPath: dst.path) {
            let conflict = Conflict(source: src, destination: dst, kind: kind, remaining: max(policy.remaining, 1))
            policy.remaining = max(policy.remaining - 1, 0)
            switch policy.decide(conflict) {
            case .cancel: result.cancelled = true; return
            case .skip: return
            case .keepBoth: dst = uniqueURL(for: dst)
            case .replace:
                do { try fm.removeItem(at: dst) }
                catch { result.failures.append(Failure(url: src, error: error)); return }
            case .merge:
                guard conflict.bothFolders else { dst = uniqueURL(for: dst); break }
                merge(src, into: dst, kind: kind, policy: &policy, result: &result)
                return
            }
        }
        do {
            switch kind {
            case .copy: try fm.copyItem(at: src, to: dst); result.created.append(dst)
            case .move: try fm.moveItem(at: src, to: dst); result.moved.append((src, dst))
            }
        } catch {
            result.failures.append(Failure(url: src, error: error))
        }
    }

    /// Finder's Merge: bring the source folder's children into the existing
    /// destination folder, asking about (or auto-resolving) child conflicts
    /// with the same batch policy. A move removes the emptied source folder.
    private static func merge(_ src: URL, into dst: URL, kind: Kind,
                              policy: inout BatchPolicy, result: inout TransferResult) {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])) ?? []
        policy.remaining += children.filter { fm.fileExists(atPath: dst.appendingPathComponent($0.lastPathComponent).path) }.count
        for child in children {
            transferOne(child, to: dst.appendingPathComponent(child.lastPathComponent), kind: kind, policy: &policy, result: &result)
            if result.cancelled { return }
        }
        if kind == .move, ((try? fm.contentsOfDirectory(atPath: src.path)) ?? []).isEmpty {
            try? fm.removeItem(at: src)
            result.moved.append((src, dst))
        }
    }

    /// Duplicate in place ("… copy"). Synchronous; duplicates are usually small.
    static func duplicate(_ urls: [URL]) -> ([URL], [Failure]) {
        var created: [URL] = []; var failures: [Failure] = []
        for src in urls {
            let dst = duplicateURL(for: src)
            do { try FileManager.default.copyItem(at: src, to: dst); created.append(dst) }
            catch { failures.append(Failure(url: src, error: error)) }
        }
        return (created, failures)
    }

    // MARK: - Standard conflict dialog (Finder's, rebuilt — macOS has no public one)

    private static func describe(_ url: URL) -> (date: Date?, size: Int64, isDir: Bool) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isPackageKey])
        return (v?.contentModificationDate, Int64(v?.fileSize ?? 0), (v?.isDirectory ?? false) && !(v?.isPackage ?? false))
    }

    /// One alert per conflict; "Apply to all" appears when more are coming.
    static func askConflict(in window: NSWindow?, _ c: Conflict) -> ConflictDecision {
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
