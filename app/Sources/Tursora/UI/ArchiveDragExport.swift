import AppKit
import UniformTypeIdentifiers

/// Dragging and sharing ZIP entries out of a pane (D101).
///
/// An entry whose bytes are here goes out as its file URL, as any file does.
/// One not extracted yet goes out as a file promise: Finder and other
/// promise-aware applications are handed the file once it has been extracted,
/// and Tursora's own panes read a private type carrying the entry's logical
/// URL, and copy it the way Copy to Other Pane does. A destination that only
/// takes paths — Terminal, the Dock — receives nothing for such an entry.
enum ArchiveDragExport {
    /// What a drag writes for an item, or nil when it cannot be dragged.
    static func writer(for item: FileItem) -> NSPasteboardWriting? {
        guard item.canAccess else { return nil }
        if let url = item.publishedContentURL { return url as NSURL }
        guard item.isArchiveEntry else { return nil }
        return ArchiveEntryPromiseProvider(item: item)
    }

    /// What Share is handed for an item: its file URL when the bytes are
    /// here, otherwise an item provider that extracts it first.
    static func sharingItem(for item: FileItem) -> Any? {
        guard item.canAccess else { return nil }
        if let url = item.publishedContentURL { return url }
        guard item.isArchiveEntry else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let location = item.url
        provider.registerFileRepresentation(forTypeIdentifier: typeIdentifier(for: item), fileOptions: [],
                                            visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let cancellation = ArchivePreparationCancellation()
            progress.cancellationHandler = { cancellation.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try ArchiveWorkspace.shared.materializeBlocking([location], cancellation: cancellation)
                    guard let url = result.urls.first else {
                        throw result.failures.first?.error ?? ArchiveBrowsingSession.SessionError.unavailableItem
                    }
                    // Not coordinated: the receiver is given its own copy.
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }

    static func typeIdentifier(for item: FileItem) -> String {
        (item.isNavigable ? UTType.folder : (item.contentType ?? .data)).identifier
    }
}

/// A ZIP entry promised to a drag destination and extracted when it asks.
/// Its own delegate: `NSFilePromiseProvider.delegate` is weak, and the drag
/// session keeps the provider alive for as long as the promise is open.
/// Sendable by construction: everything it holds is fixed at init, and AppKit
/// calls it on the operation queue it names.
final class ArchiveEntryPromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    /// Carries the entry's logical URL to Tursora's own drop targets, which
    /// copy it by that URL instead of waiting for a promise to be kept. Every
    /// drop target registers it next to `.fileURL`.
    static let internalType = NSPasteboard.PasteboardType("org.tursora.archive-entry")

    let logicalURL: URL
    private let name: String
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(item: FileItem) {
        logicalURL = item.url
        name = item.name
        super.init()
        fileType = ArchiveDragExport.typeIdentifier(for: item)
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.internalType]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == Self.internalType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == Self.internalType else { return super.pasteboardPropertyList(forType: type) }
        // The process, so a drop in another copy of Tursora is not taken for
        // one of its own entries.
        return ["url": logicalURL.absoluteString, "pid": NSNumber(value: getpid())]
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    /// Extracts the entry — a folder with its whole subtree, a package whole —
    /// then copies it to where the destination asked.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            let result = try ArchiveWorkspace.shared.materializeBlocking([logicalURL])
            guard let source = result.urls.first else {
                throw result.failures.first?.error ?? ArchiveBrowsingSession.SessionError.unavailableItem
            }
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// The logical URLs of this process's own promised entries on a pasteboard.
    static func logicalURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: internalType) as? [String: Any],
                  (plist["pid"] as? NSNumber)?.int32Value == getpid(),
                  let string = plist["url"] as? String else { return nil }
            return URL(string: string)
        }
    }
}
