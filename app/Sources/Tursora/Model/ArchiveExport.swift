import Foundation

/// External recipients cannot represent a folder plus a list of missing
/// members. Promises and sharing therefore export only a complete result;
/// the browser's own transfers can still report partial completion explicitly.
enum ArchiveExport {
    struct IncompleteExportError: LocalizedError {
        let failures: [FileOperations.Failure]

        var errorDescription: String? {
            let count = failures.count
            let names = failures.prefix(5).map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
            let remaining = count > 5 ? ", and \(count - 5) more" : ""
            let reason = failures.first.map { " \($0.error.localizedDescription)" } ?? ""
            return "The item could not be exported completely. \(count) archive \(count == 1 ? "member" : "members") could not be read: \(names)\(remaining).\(reason)"
        }
    }

    /// One requested entry, including every descendant of a folder or package.
    /// A URL may coexist with failures, so its presence alone is not success.
    static func completeURL(in result: ArchiveMaterializationResult) throws -> URL {
        guard result.failures.isEmpty else { throw IncompleteExportError(failures: result.failures) }
        guard result.urls.count == 1, let url = result.urls.first else {
            throw ArchiveBrowsingSession.SessionError.unavailableItem
        }
        return url
    }

    /// Already complete, without extracting. A previously failed folder must
    /// still go through a promise/provider so its receiver gets the error.
    static func publishedURL(for location: URL, workspace: ArchiveWorkspace = .shared) -> URL? {
        guard let result = try? workspace.publishedResult(for: [location]) else { return nil }
        return try? completeURL(in: result)
    }

    /// A copy that can outlive the archive session, for a sharing service.
    static func handOff(_ location: URL, workspace: ArchiveWorkspace = .shared,
                        store: ArchiveHandoffStore = .shared,
                        cancellation: ArchivePreparationCancellation? = nil) throws -> URL {
        let result = try workspace.materializeBlocking([location], cancellation: cancellation)
        let source = try completeURL(in: result)
        guard let copy = store.handOff(source, logical: location) else {
            throw ArchiveBrowsingSession.SessionError.unavailableItem
        }
        return copy
    }

    /// A promised item is published at the destination only once its complete
    /// archive contents and the destination copy have both succeeded.
    static func writePromise(from location: URL, to destination: URL,
                             workspace: ArchiveWorkspace = .shared) throws {
        let result = try workspace.materializeBlocking([location])
        let source = try completeURL(in: result)
        try FileOperations.copyArchiveExport(source, to: destination)
    }
}

extension FileOperations {
    static func copyArchiveExport(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".tursora-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(destination.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        // Same destination volume: no partially copied folder is published,
        // and an existing destination is never replaced by a file promise.
        try fm.moveItem(at: copy, to: destination)
    }
}
