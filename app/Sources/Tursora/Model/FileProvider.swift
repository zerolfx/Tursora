import Foundation

/// The one seam that must exist from day one: everything the UI knows about a
/// filesystem goes through here. v1 ships only `LocalFileProvider`; a remote
/// backend later slots in without touching the view layer.
protocol FileProvider: AnyObject {
    /// Blocking; callers are expected to run this off the main thread.
    func listDirectory(_ url: URL) throws -> [FileItem]
    var homeURL: URL { get }
    func displayName(for url: URL) -> String
}

final class LocalFileProvider: FileProvider {
    private let fm = FileManager.default

    func listDirectory(_ url: URL) throws -> [FileItem] {
        try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: []
        ).compactMap(FileItem.init(url:))
    }

    var homeURL: URL { fm.homeDirectoryForCurrentUser }

    /// Uses Finder's localized names ("Desktop" stays "Desktop" in a localized
    /// system, volumes show their volume name, etc.).
    func displayName(for url: URL) -> String {
        if url.path == "/" {
            if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName { return name }
        }
        return fm.displayName(atPath: url.path)
    }
}
