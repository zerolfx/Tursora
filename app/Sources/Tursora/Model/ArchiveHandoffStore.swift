import Foundation
import Darwin

/// Copies of ZIP entries handed to something Tursora cannot see finish with
/// them: an application a file was opened in, Finder pasting or dropping it,
/// a sharing service, the Quick Look panel's own buttons (D103).
///
/// A ZIP's private copy is let go once no pane shows it (ArchiveWorkspace),
/// so a file handed out of it must not live there. Each is an APFS clone in a
/// folder of its own: made instantly, sharing blocks with the extracted file
/// — so it costs no space until the ZIP's copy is let go — and outliving that
/// copy. The folder is removed at quit, as the ZIP's copy always was, and one
/// left by a crash is removed at the next launch under the same advisory lock
/// as session storage.
final class ArchiveHandoffStore {
    static let shared = ArchiveHandoffStore()
    static let prefix = "tursora-zip-handoff-"

    private let root: URL
    private let lock = NSLock()
    private var directory: URL?
    private var lockDescriptor: Int32 = -1
    /// One copy per extracted item and name, so opening a file twice hands out
    /// one path — while that copy is still what was handed out.
    private var copies: [String: (copy: URL, size: Int64, modified: Date?)] = [:]
    /// Where each copy came from, for the Quick Look zoom's source frame.
    private var origins: [String: URL] = [:]

    init(root: URL = FileManager.default.temporaryDirectory) { self.root = root }

    /// A copy of an extracted item for another application, or nil when none
    /// could be made — the caller then hands out nothing. A link is followed
    /// first, since the copy has to stand on its own away from the archive's
    /// tree, but the copy keeps the entry's own name.
    func handOff(_ physical: URL, logical: URL) -> URL? {
        let source = physical.resolvingSymlinksInPath().standardizedFileURL
        let name = logical.lastPathComponent.isEmpty ? source.lastPathComponent : logical.lastPathComponent
        let key = source.path + "\u{0}" + name
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        // A file handed out before is handed out again only while it is still
        // what it was: an application may have saved changes into it, and a
        // folder may have filled in since. Anything else gets a fresh clone.
        if let existing = copies[key], let stamp = Self.stamp(existing.copy),
           !Self.isDirectory(existing.copy), stamp.size == existing.size, stamp.modified == existing.modified {
            return existing.copy
        }
        guard let directory = ensureDirectory() else { return nil }
        let holder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: holder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        let copy = holder.appendingPathComponent(name)
        // A clone copies extended attributes, the download quarantine included.
        let cloned = source.withUnsafeFileSystemRepresentation { from in
            copy.withUnsafeFileSystemRepresentation { to in clonefile(from!, to!, UInt32(CLONE_NOFOLLOW)) == 0 }
        }
        if !cloned {
            do { try fm.copyItem(at: source, to: copy) } catch { try? fm.removeItem(at: holder); return nil }
        }
        if let stamp = Self.stamp(copy) { copies[key] = (copy, stamp.size, stamp.modified) }
        origins[copy.standardizedFileURL.path] = logical
        return copy
    }

    private static func stamp(_ url: URL) -> (size: Int64, modified: Date?)? {
        // FileManager, not URL resource values, which are cached for the pass.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return ((attributes[.size] as? NSNumber)?.int64Value ?? 0, attributes[.modificationDate] as? Date)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// The entry a handed-out copy stands for.
    func logicalURL(forHandOff url: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return origins[url.standardizedFileURL.path]
    }

    /// Whether a URL is one of these copies.
    func contains(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let directory else { return false }
        return ArchiveBrowsingSession.containsPath(root: directory.resolvingSymlinksInPath(),
                                                   candidate: url.resolvingSymlinksInPath())
    }

    /// At quit: every copy goes, as the ZIPs' private copies always have.
    func removeAll() {
        lock.lock()
        let directory = self.directory
        let descriptor = lockDescriptor
        self.directory = nil
        lockDescriptor = -1
        copies.removeAll()
        origins.removeAll()
        lock.unlock()
        ArchiveBrowsingSession.releaseStorageLock(descriptor)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    var directoryForTesting: URL? { lock.lock(); defer { lock.unlock() }; return directory }

    private func ensureDirectory() -> URL? {
        if let directory, FileManager.default.fileExists(atPath: directory.path) { return directory }
        let made = root.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        // Owned like session storage, so another process's launch sweep
        // leaves it alone for as long as this one lives.
        ArchiveBrowsingSession.releaseStorageLock(lockDescriptor)
        lockDescriptor = ArchiveBrowsingSession.takeStorageLock(in: made)
        directory = made
        copies.removeAll()
        origins.removeAll()
        return made
    }
}
