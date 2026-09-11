import Foundation
import CoreServices

/// Watches a directory with FSEvents and reports changed paths on the main
/// queue. Per-file events for the subtree are delivered; the owner filters
/// them down to the folders it actually displays. Dolphin does the same
/// job with KDirWatch.
final class DirectoryWatcher {

    let directory: URL
    private let handler: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(directory: URL, handler: @escaping ([String]) -> Void) {
        self.directory = directory
        self.handler = handler
        start()
    }

    deinit { stop() }

    private func start() {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray as? [String] ?? []
            watcher.handler(paths)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let realPath = directory.resolvingSymlinksInPath().path
        guard let s = FSEventStreamCreate(nil, callback, &context, [realPath] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

extension Notification.Name {
    /// Posted after an in-app file operation with userInfo["directories"]: [URL]
    /// so every pane showing one of them refreshes at once, without waiting
    /// for FSEvents.
    static let tursoraDirectoriesChanged = Notification.Name("tursora.directoriesChanged")
}

enum DirectoryChanges {
    /// `renamed` lets listeners follow an item to its new name (a pane keeps
    /// it selected, an Info window keeps showing it).
    static func post(_ urls: [URL], renamed: (from: URL, to: URL)? = nil) {
        let dirs = Set(urls.map { $0.standardizedFileURL })
        var info: [String: Any] = ["directories": Array(dirs)]
        if let renamed {
            info["renamedFrom"] = renamed.from
            info["renamedTo"] = renamed.to
        }
        NotificationCenter.default.post(name: .tursoraDirectoriesChanged, object: nil, userInfo: info)
    }

    /// The directories an operation on `urls` (landing in `destination`) touches.
    static func affected(sources: [URL], destination: URL? = nil) -> [URL] {
        var out = sources.map { $0.deletingLastPathComponent() }
        if let destination { out.append(destination) }
        return out
    }
}
