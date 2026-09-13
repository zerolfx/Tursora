import Foundation
import Darwin

/// A private extracted snapshot. Its URLs never replace the original archive,
/// and every directory read or file launch rechecks the resolved containment.
final class ArchiveBrowsingSession {
    private static let preparationLock = NSLock()
    private static var pendingStorage: [URL: ArchivePreparationCancellation] = [:]
    private static var isShuttingDown = false

    /// Stop child writers before their workers reclaim private directories.
    /// ArchiveWorkspace's shutdown barrier waits for the resulting completions.
    static func shutdownPreparingSessions() {
        preparationLock.lock()
        isShuttingDown = true
        let pending = pendingStorage
        preparationLock.unlock()
        pending.values.forEach { $0.cancel() }
    }

    fileprivate static func registerPreparation(_ url: URL, cancellation: ArchivePreparationCancellation) -> Bool {
        preparationLock.lock(); defer { preparationLock.unlock() }
        guard !isShuttingDown else { return false }
        pendingStorage[url] = cancellation
        return true
    }

    fileprivate static func finishPreparation(_ url: URL) {
        preparationLock.lock(); defer { preparationLock.unlock() }
        pendingStorage[url] = nil
    }

    struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isPackage: Bool
        let isSymbolicLink: Bool
        let canAccess: Bool
        let size: Int64
        var isNavigable: Bool { isDirectory && !isPackage && canAccess }
    }

    enum SessionError: LocalizedError {
        case closed, cancelled, outsideArchive, notDirectory, unavailableItem
        var errorDescription: String? {
            switch self {
            case .closed: return "This ZIP browsing session has ended."
            case .cancelled: return "Opening the ZIP was cancelled."
            case .outsideArchive: return "This link points outside the ZIP and cannot be opened here."
            case .notDirectory: return "This item is not a folder."
            case .unavailableItem: return "This item is unavailable in the ZIP snapshot."
            }
        }
    }

    let archiveURL: URL
    let storageURL: URL
    let rootURL: URL
    private let storageFileID: UInt64
    private let stateLock = NSLock()
    private var closed = false
    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    fileprivate init(archive: URL, storage: URL, root: URL, fileID: UInt64) {
        archiveURL = archive.standardizedFileURL
        storageURL = storage
        rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        storageFileID = fileID
    }

    @discardableResult
    static func prepare(archive: URL, logicalArchiveURL: URL? = nil,
                        cancellation: ArchivePreparationCancellation = ArchivePreparationCancellation(),
                        completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) -> ArchivePreparationCancellation {
        FileOperations.prepareArchiveBrowsingSession(archive: archive, logicalArchiveURL: logicalArchiveURL,
                                                      cancellation: cancellation, completion: completion)
        return cancellation
    }

    static func containsPath(root: URL, candidate: URL) -> Bool {
        candidate.isFileURL && candidate.standardizedFileURL.pathComponents
            .starts(with: root.standardizedFileURL.pathComponents)
    }

    func validatedURL(_ url: URL) throws -> URL {
        guard !isClosed else { throw SessionError.closed }
        guard Self.containsPath(root: rootURL, candidate: url),
              Self.containsPath(root: rootURL, candidate: url.resolvingSymlinksInPath()) else {
            throw SessionError.outsideArchive
        }
        return url.standardizedFileURL
    }

    func entries(in directory: URL, beforeReadingEntry: ((URL) throws -> Void)? = nil) throws -> [Entry] {
        let directory = try validatedURL(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionError.notDirectory
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
        return try urls.compactMap { url -> Entry? in
            let attributes: [FileAttributeKey: Any]
            do {
                try beforeReadingEntry?(url)
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                let failure = error as NSError
                // Editors commonly replace a temporary document atomically.
                // Only a vanished child is skipped; permissions/I/O errors
                // still surface instead of silently hiding a damaged snapshot.
                if (failure.domain == NSCocoaErrorDomain
                    && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code))
                    || (failure.domain == NSPOSIXErrorDomain && failure.code == ENOENT) { return nil }
                throw error
            }
            let link = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            let contained = (try? validatedURL(url)) != nil
            // Do not inspect an escaped link's target, even just for its icon or size.
            let target = link ? url.resolvingSymlinksInPath() : url
            let values = contained ? try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey]) : nil
            return Entry(url: url, name: url.lastPathComponent, isDirectory: values?.isDirectory == true,
                         isPackage: values?.isPackage == true, isSymbolicLink: link,
                         canAccess: contained && values != nil, size: Int64(values?.fileSize ?? 0))
        }.sorted {
            if $0.isNavigable != $1.isNavigable { return $0.isNavigable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        FileOperations.discardArchiveBrowsingSession(storageURL, fileID: storageFileID)
    }
}

extension FileOperations {
    static func prepareArchiveBrowsingSession(archive: URL, logicalArchiveURL: URL? = nil,
        cancellation: ArchivePreparationCancellation = ArchivePreparationCancellation(),
        completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let storage = fm.temporaryDirectory.appendingPathComponent("tursora-zip-session-" + UUID().uuidString)
            var storageID: UInt64?
            do {
                try cancellation.checkCancellation()
                try fm.createDirectory(at: storage, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let id = (try fm.attributesOfItem(atPath: storage.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                storageID = id
                guard ArchiveBrowsingSession.registerPreparation(storage, cancellation: cancellation) else {
                    throw ArchiveBrowsingSession.SessionError.closed
                }
                try cancellation.checkpoint(.storageCreated(storage))
                extractArchiveContents(archive: archive, to: storage, cancellation: cancellation) { result in
                    DispatchQueue.global(qos: .utility).async {
                        let prepared: Result<ArchiveBrowsingSession, Error>
                        if cancellation.isCancelled {
                            discardArchiveBrowsingSession(storage, fileID: id)
                            prepared = .failure(ArchiveBrowsingSession.SessionError.cancelled)
                        } else {
                            switch result {
                            case .success(let root):
                                prepared = .success(ArchiveBrowsingSession(archive: logicalArchiveURL ?? archive, storage: storage, root: root, fileID: id))
                            case .failure(let error):
                                discardArchiveBrowsingSession(storage, fileID: id)
                                prepared = .failure(error)
                            }
                        }
                        ArchiveBrowsingSession.finishPreparation(storage)
                        DispatchQueue.main.async { completion(prepared) }
                    }
                }
            } catch {
                ArchiveBrowsingSession.finishPreparation(storage)
                if let storageID { discardArchiveBrowsingSession(storage, fileID: storageID) }
                else { try? fm.removeItem(at: storage) }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    fileprivate static func discardArchiveBrowsingSession(_ storage: URL, fileID: UInt64) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: storage.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == fileID else { return }
        // removeItem removes symlinks themselves; it does not traverse their targets.
        try? fm.removeItem(at: storage)
    }
}
