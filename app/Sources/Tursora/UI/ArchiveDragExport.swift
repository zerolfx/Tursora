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
        guard item.isArchiveEntry else { return item.publishedContentURL.map { $0 as NSURL } }
        if let url = item.publishedContentURL { return ArchiveHandoffPasteboardItem.make(physical: url, logical: item.url) }
        return ArchiveEntryPromiseProvider(item: item)
    }

    /// What Share is handed for an item: its file URL when the bytes are
    /// here, otherwise an item provider that extracts it first.
    static func sharingItem(for item: FileItem) -> Any? {
        guard item.canAccess else { return nil }
        guard item.isArchiveEntry else { return item.publishedContentURL }
        // A sharing service reads the file when it likes: it is given a
        // hand-off copy, outside the ZIP's private copy (D103).
        if let url = item.publishedContentURL { return ArchiveHandoffStore.shared.handOff(url, logical: item.url) }
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let location = item.url
        // Held until the provider delivers the file, or goes away unused (D103).
        let lease = ArchiveWorkspace.shared.lease([location])
        provider.registerFileRepresentation(forTypeIdentifier: typeIdentifier(for: item), fileOptions: [],
                                            visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let cancellation = ArchivePreparationCancellation()
            progress.cancellationHandler = { cancellation.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try ArchiveWorkspace.shared.materializeBlocking([location], cancellation: cancellation)
                    guard let url = result.urls.first,
                          let copy = ArchiveHandoffStore.shared.handOff(url, logical: location) else {
                        throw result.failures.first?.error ?? ArchiveBrowsingSession.SessionError.unavailableItem
                    }
                    // Not coordinated: the receiver is given its own copy.
                    completion(copy, false, nil)
                    lease.release()
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

/// An extracted ZIP entry on a drag pasteboard (D103). Tursora's own drop
/// targets read the private type and copy by the logical URL. Another
/// application asking for the file URL is given a hand-off copy, made only
/// then — a drag that ends inside Tursora, or nowhere, clones nothing.
final class ArchiveHandoffPasteboardItem: NSObject, NSPasteboardItemDataProvider {
    private let physical: URL
    private let logical: URL
    /// Kept alive until the pasteboard is done with them; main thread only.
    private static var retained: [ObjectIdentifier: ArchiveHandoffPasteboardItem] = [:]

    private init(physical: URL, logical: URL) {
        self.physical = physical
        self.logical = logical
    }

    static func make(physical: URL, logical: URL) -> NSPasteboardItem {
        let provider = ArchiveHandoffPasteboardItem(physical: physical, logical: logical)
        retained[ObjectIdentifier(provider)] = provider
        let item = NSPasteboardItem()
        item.setPropertyList(ArchiveEntryPromiseProvider.internalPropertyList(for: logical),
                             forType: ArchiveEntryPromiseProvider.internalType)
        item.setDataProvider(provider, forTypes: [.fileURL])
        return item
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL, let copy = ArchiveHandoffStore.shared.handOff(physical, logical: logical) else { return }
        item.setString(copy.absoluteString, forType: .fileURL)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Self.retained[ObjectIdentifier(self)] = nil
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
        return Self.internalPropertyList(for: logicalURL)
    }

    /// The process, so a drop in another copy of Tursora is not taken for one
    /// of its own entries.
    static func internalPropertyList(for logical: URL) -> [String: Any] {
        ["url": logical.absoluteString, "pid": NSNumber(value: getpid())]
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    /// Extracts the entry — a folder with its whole subtree, a package whole —
    /// then copies it to where the destination asked.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // Held while the promise is being kept: the ZIP's private copy is read
        // until the copy at the destination is complete (D103). A drop lands
        // while the pane that started the drag still shows the ZIP, so nothing
        // needs holding before.
        let lease = ArchiveWorkspace.shared.lease([logicalURL])
        defer { lease.release() }
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

    /// This process's own ZIP entries among pasteboard items, by item index.
    static func logicalURLs(in items: [NSPasteboardItem]) -> [Int: URL] {
        var urls: [Int: URL] = [:]
        for (index, item) in items.enumerated() {
            guard let plist = item.propertyList(forType: internalType) as? [String: Any],
                  (plist["pid"] as? NSNumber)?.int32Value == getpid(),
                  let string = plist["url"] as? String, let url = URL(string: string) else { continue }
            urls[index] = url
        }
        return urls
    }
}
