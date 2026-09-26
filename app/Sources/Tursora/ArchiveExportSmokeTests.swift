import AppKit
import UniformTypeIdentifiers

/// External exports must report missing members instead of silently handing
/// another application a partial folder. Listing names must also survive a
/// read boundary inside a UTF-8 character.
enum ArchiveExportSmokeTests: SmokeSuite {
    static let checkPrefix = "archive export: "

    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            var root: URL?
            var mounted: [URL] = []
            defer {
                mounted.forEach { ArchiveWorkspace.shared.discard(archive: $0) }
                if let root { try? FileManager.default.removeItem(at: root) }
                completion()
            }
            do {
                let fixture = try SmokeFixtures.temporaryDirectory("archive-export")
                root = fixture
                print("== complete archive exports and Unicode listing boundaries ==")
                try completenessChecks(root: fixture)
                try listingChecks(root: fixture)
                try await unconfirmedMemberChecks(root: fixture)
                try await promiseChecks(root: fixture, mounted: &mounted)
                try await sharingChecks(root: fixture, mounted: &mounted)
            } catch {
                check("unexpected error", false, "\(error)")
            }
        }
    }

    private static func completenessChecks(root: URL) throws {
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let clean = ArchiveMaterializationResult(urls: [folder])
        try require("a complete single result keeps its URL", try ArchiveExport.completeURL(in: clean) == folder)
        let missing: [FileOperations.Failure] = ["one.txt", "two.txt"].map {
            .init(url: folder.appendingPathComponent($0), error: ArchiveBrowsingSession.SessionError.unavailableItem)
        }
        do {
            _ = try ArchiveExport.completeURL(in: .init(urls: [folder], failures: missing))
            throw SmokeFailure("a partial result was accepted")
        } catch let error as ArchiveExport.IncompleteExportError {
            try require("a parent URL never hides failed descendants, and the error names them",
                        error.failures.count == 2 && error.localizedDescription.contains("2 archive members")
                        && error.localizedDescription.contains("one.txt") && error.localizedDescription.contains("two.txt"))
        }
        do {
            _ = try ArchiveExport.completeURL(in: .init())
            throw SmokeFailure("an empty result was accepted")
        } catch ArchiveBrowsingSession.SessionError.unavailableItem {
            try require("an empty result cannot be exported", true)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("whole".utf8).write(to: folder.appendingPathComponent("member.txt"))
        let output = root.appendingPathComponent("Published", isDirectory: true)
        try FileOperations.copyArchiveExport(folder, to: output)
        try require("a complete folder is published with its member",
                    try String(contentsOf: output.appendingPathComponent("member.txt"), encoding: .utf8) == "whole")
        try Data("existing".utf8).write(to: output.appendingPathComponent("member.txt"))
        do {
            try FileOperations.copyArchiveExport(folder, to: output)
            throw SmokeFailure("an existing promise destination was replaced")
        } catch is SmokeFailure {
            throw SmokeFailure("an existing promise destination was replaced")
        } catch {
            try require("a failed destination publish preserves the existing folder and removes staging",
                        try String(contentsOf: output.appendingPathComponent("member.txt"), encoding: .utf8) == "existing"
                        && !fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".tursora-export-") })
        }
    }

    private static func listingChecks(root: URL) throws {
        let filler = "-rw-r--r--  0 501    0          20 Sep 22 23:02 filler.txt\n"
        let prefix = "-rw-r--r--  0 501    0          20 Sep 22 23:02 "
        for (name, width) in [("中文.txt", 3), ("📦.txt", 4)] {
            for firstChunkBytes in 1..<width {
                let nameOffset = BSDTarArchiveListing.readChunkBytes - firstChunkBytes
                let count = (nameOffset - prefix.utf8.count) / filler.utf8.count
                let padding = nameOffset - prefix.utf8.count - count * filler.utf8.count
                // Extra spaces between mode and link count are ordinary
                // listing whitespace; every line is a valid record.
                let alignedPrefix = "-rw-r--r--" + String(repeating: " ", count: padding + 2)
                    + "0 501    0          20 Sep 22 23:02 "
                let bytes = Data((String(repeating: filler, count: count) + alignedPrefix + name
                                  + "\n" + prefix + "last.txt").utf8)
                let listing = root.appendingPathComponent("listing.txt")
                try bytes.write(to: listing)
                let entries = try BSDTarArchiveListing.parse(listing)
                try require("\(name) survives a chunk split after UTF-8 byte \(firstChunkBytes)",
                            entries.count == count + 2 && entries[count].name == name
                            && entries.last?.name == "last.txt", "\(entries.suffix(2).map(\.name))")
            }
        }
    }

    /// The runner's log can omit a member, for example at its size limit.
    /// The extractor wrote the bytes, but the materializer must leave that
    /// member unpublished; the external export then has to fail as well.
    private final class MissingAnnouncementRunner: ArchiveToolRunning {
        func run(_ arguments: [String], scratch: URL,
                 cancellation: ArchivePreparationCancellation?) throws -> ArchiveToolRun {
            let result = try SystemArchiveToolRunner.shared.run(arguments, scratch: scratch, cancellation: cancellation)
            let log = result.log.components(separatedBy: "\n").filter { $0 != "x Folder/bad.txt" }.joined(separator: "\n")
            return ArchiveToolRun(status: result.status, log: log)
        }
    }

    @MainActor private static func unconfirmedMemberChecks(root: URL) async throws {
        let archive = root.appendingPathComponent("unconfirmed.zip")
        try SmokeFixtures.zip([("Folder/good.txt", "good"), ("Folder/bad.txt", "unconfirmed")]).write(to: archive)
        let workspace = ArchiveWorkspace(materializationPolicy: .never, preparer: { source, logical, completion in
            let cancellation = ArchivePreparationCancellation()
            FileOperations.prepareArchiveBrowsingSession(archive: source, logicalArchiveURL: logical,
                                                          runner: MissingAnnouncementRunner(), cancellation: cancellation,
                                                          completion: completion)
            return cancellation
        })
        defer { workspace.shutdownAll() }
        let session: ArchiveBrowsingSession = try await withCheckedThrowingContinuation { continuation in
            workspace.prepare(archive: archive) { continuation.resume(with: $0) }
        }
        let destination = root.appendingPathComponent("unconfirmed-export", isDirectory: true)
        let failure: Error? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try ArchiveExport.writePromise(from: archive.appendingPathComponent("Folder"), to: destination,
                                                   workspace: workspace)
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error) }
            }
        }
        try require("an unconfirmed descendant is reported by name and no partial folder is published",
                    session.materializer.state(of: "Folder/good.txt") == .published
                    && session.materializer.state(of: "Folder/bad.txt") == .absent
                    && failure is ArchiveExport.IncompleteExportError
                    && failure?.localizedDescription.contains("bad.txt") == true
                    && !FileManager.default.fileExists(atPath: destination.path), "\(String(describing: failure))")
    }

    @MainActor private static func mountedCorruptFolder(_ name: String, root: URL,
                                                        mounted: inout [URL]) async throws -> FileItem {
        let archive = root.appendingPathComponent(name + ".zip")
        var data = SmokeFixtures.zip([("Folder/good.txt", "good"), ("Folder/bad.txt", "corrupt me")])
        guard let range = data.range(of: Data("corrupt me".utf8)) else {
            throw SmokeFailure("the export fixture has no member to corrupt")
        }
        data[range.lowerBound] ^= 0xff
        try data.write(to: archive)
        mounted.append(archive)
        let session: ArchiveBrowsingSession = try await withCheckedThrowingContinuation { continuation in
            ArchiveWorkspace.shared.prepare(archive: archive) { continuation.resume(with: $0) }
        }
        guard let entry = try session.entries(in: session.rootURL).first(where: { $0.name == "Folder" }) else {
            throw SmokeFailure("the export fixture has no folder")
        }
        return FileItem(archiveEntry: entry, logicalURL: archive.appendingPathComponent("Folder"), session: session)
    }

    @MainActor private static func promiseError(for item: FileItem, to destination: URL) async throws -> Error? {
        guard let promise = ArchiveDragExport.writer(for: item) as? ArchiveEntryPromiseProvider else {
            throw SmokeFailure("an incomplete folder did not use a file promise")
        }
        return await withCheckedContinuation { continuation in
            promise.operationQueue(for: promise).addOperation {
                promise.filePromiseProvider(promise, writePromiseTo: destination) {
                    continuation.resume(returning: $0)
                }
            }
        }
    }

    @MainActor private static func promiseChecks(root: URL, mounted: inout [URL]) async throws {
        // ArchiveOpenSmokeTests covers successful real file, folder and package callbacks.
        let item = try await mountedCorruptFolder("promise-broken", root: root, mounted: &mounted)
        let destination = root.appendingPathComponent("promised-folder", isDirectory: true)
        for attempt in 1...2 {
            let error = try await promiseError(for: item, to: destination)
            try require("promise attempt \(attempt) reports the damaged member and publishes no destination",
                        error is ArchiveExport.IncompleteExportError
                        && error?.localizedDescription.contains("bad.txt") == true
                        && !FileManager.default.fileExists(atPath: destination.path), "\(String(describing: error))")
        }
        try require("settled failures cannot turn a repeated drag into a successful file URL",
                    item.publishedContentURL != nil && ArchiveExport.publishedURL(for: item.url) == nil)
    }

    @MainActor private static func sharingChecks(root: URL, mounted: inout [URL]) async throws {
        let item = try await mountedCorruptFolder("share-broken", root: root, mounted: &mounted)
        for attempt in 1...2 {
            guard let provider = ArchiveDragExport.sharingItem(for: item) as? NSItemProvider else {
                throw SmokeFailure("an incomplete shared folder bypassed its item provider")
            }
            let loaded: (URL?, Error?) = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.folder.identifier) { url, error in
                    continuation.resume(returning: (url, error))
                }
            }
            try require("Share attempt \(attempt) reports the damaged member without supplying a partial folder",
                        loaded.0 == nil && errorDescription(loaded.1).contains("bad.txt"), errorDescription(loaded.1))
        }
    }

    private static func errorDescription(_ error: Error?) -> String {
        guard let error else { return "no error" }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        return error.localizedDescription + (underlying.map { " " + errorDescription($0) } ?? "")
    }
}
