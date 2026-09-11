import Foundation

/// A private extracted snapshot. Its URLs never replace the original archive,
/// and every directory read or file launch rechecks the resolved containment.
final class ArchiveBrowsingSession {
    private static let preparationLock = NSLock()
    private static var pendingStorage: [URL: UInt64] = [:]
    private static var isShuttingDown = false

    /// App exit also discards private directories whose extraction has not yet
    /// completed. A late extractor can fail only within its removed workspace.
    static func shutdownPreparingSessions() {
        preparationLock.lock()
        isShuttingDown = true
        let pending = pendingStorage
        pendingStorage.removeAll()
        preparationLock.unlock()
        for (url, id) in pending { FileOperations.discardArchiveBrowsingSession(url, fileID: id) }
    }

    fileprivate static func registerPreparation(_ url: URL, fileID: UInt64) -> Bool {
        preparationLock.lock(); defer { preparationLock.unlock() }
        guard !isShuttingDown else { return false }
        pendingStorage[url] = fileID
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
        case closed, outsideArchive, notDirectory, unavailableItem
        var errorDescription: String? {
            switch self {
            case .closed: return "This ZIP browsing session has ended."
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
        archiveURL = archive.resolvingSymlinksInPath().standardizedFileURL
        storageURL = storage
        rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        storageFileID = fileID
    }

    static func prepare(archive: URL, completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) {
        FileOperations.prepareArchiveBrowsingSession(archive: archive, completion: completion)
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

    func entries(in directory: URL) throws -> [Entry] {
        let directory = try validatedURL(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionError.notDirectory
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
        return try urls.map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
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
    static func prepareArchiveBrowsingSession(archive: URL,
        completion: @escaping (Result<ArchiveBrowsingSession, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let storage = fm.temporaryDirectory.appendingPathComponent("tursora-zip-session-" + UUID().uuidString)
            do {
                try fm.createDirectory(at: storage, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let id = (try fm.attributesOfItem(atPath: storage.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                guard ArchiveBrowsingSession.registerPreparation(storage, fileID: id) else {
                    discardArchiveBrowsingSession(storage, fileID: id)
                    DispatchQueue.main.async { completion(.failure(ArchiveBrowsingSession.SessionError.closed)) }
                    return
                }
                extractArchiveContents(archive: archive, to: storage) { result in
                    ArchiveBrowsingSession.finishPreparation(storage)
                    switch result {
                    case .success(let root):
                        completion(.success(ArchiveBrowsingSession(archive: archive, storage: storage, root: root, fileID: id)))
                    case .failure(let error):
                        discardArchiveBrowsingSession(storage, fileID: id)
                        completion(.failure(error))
                    }
                }
            } catch {
                try? fm.removeItem(at: storage)
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
