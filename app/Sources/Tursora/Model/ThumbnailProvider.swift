import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One cell's interest in a thumbnail, so the cell can withdraw it when it is
/// reused or scrolled away (D100).
final class ThumbnailToken {}

/// Content previews: readable text excerpts and platform Quick Look images.
/// Generated lazily and cached by path, point size, display scale and file
/// modification stamp, with concurrent requests for the same image coalesced.
final class ThumbnailProvider {

    typealias Loader = (FileItem, CGFloat, CGFloat, ThumbnailToken, @escaping (NSImage?) -> Void) -> NSImage?

    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private struct Waiter {
        let token: ThumbnailToken
        let completion: (NSImage?) -> Void
    }
    /// A key present here is being made; its waiters may all have gone, and it
    /// is still kept, so the image lands in the cache.
    private var pending: [String: [Waiter]] = [:]
    private var keyOfToken: [ObjectIdentifier: String] = [:]
    /// Files whose type has no thumbnailer — remembered so they are not retried on every scroll.
    private var unsupported = Set<String>()

    private init() { cache.countLimit = 3000 }

    /// Pure for a ZIP entry — it reads the row, never the disk — because it is
    /// asked for every cell drawn: readable, a file, small enough to extract
    /// unasked, and a type something can draw (D100).
    static func canPreview(_ item: FileItem) -> Bool {
        guard !item.isNavigable, !item.isPackage else { return false }
        guard item.isArchiveEntry else { return item.publishedContentURL != nil }
        guard item.canAccess, item.size <= ArchivePreviewLimit.automaticBytes else { return false }
        return hasThumbnailer(item)
    }

    /// Text is drawn here; the platform thumbnailer draws images, PDFs, movies
    /// and office documents. Anything else would be extracted to get the
    /// generic icon back.
    private static func hasThumbnailer(_ item: FileItem) -> Bool {
        let type = item.contentType ?? UTType(filenameExtension: item.url.pathExtension)
        if TextThumbnailRenderer.isTextType(type, pathExtension: item.url.pathExtension) { return true }
        guard let type else { return false }
        return [.image, .pdf, .audiovisualContent, .rtf, .presentation, .spreadsheet, .compositeContent]
            .contains { type.conforms(to: $0) }
    }

    static func cacheKey(for item: FileItem, size: CGFloat, scale: CGFloat) -> String {
        "\(item.contentURL.path)|\(size)|\(scale)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|\(item.size)"
    }

    /// Returns a cached thumbnail at once, otherwise nil and calls back later on
    /// the main thread (with nil if the file has no preview). Withdraw the
    /// request with `cancel(_:)` when the cell no longer wants it.
    @discardableResult
    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat, token: ThumbnailToken = ThumbnailToken(),
                   completion: @escaping (NSImage?) -> Void) -> NSImage? {
        guard Self.canPreview(item) else { return nil }
        let k = Self.cacheKey(for: item, size: size, scale: scale)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if unsupported.contains(k) { return nil }
        keyOfToken[ObjectIdentifier(token)] = k
        if pending[k] != nil { pending[k]!.append(Waiter(token: token, completion: completion)); return nil }
        pending[k] = [Waiter(token: token, completion: completion)]

        // `remember` records a miss for good. Only a thumbnailer's own nil, or
        // the archive tool naming the member in an error, is a real miss; a
        // cancelled or refused extraction must not poison the key.
        let deliver: (NSImage?, _ remember: Bool) -> Void = { [weak self] image, remember in
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.cache.setObject(image, forKey: k as NSString) }
                else if remember { self.unsupported.insert(k) }
                let waiters = self.pending.removeValue(forKey: k) ?? []
                waiters.forEach { self.keyOfToken[ObjectIdentifier($0.token)] = nil }
                waiters.forEach { $0.completion(image) }
            }
        }

        // A ZIP entry not extracted yet: its bytes come through the queue,
        // one transient extraction for everything asked for in this pass.
        if item.isArchiveEntry, !item.isExtractedArchiveEntry, let location = item.archiveLocation {
            ArchiveThumbnailQueue.shared.request(ArchiveThumbnailQueue.Request(
                key: k, session: location.session, path: location.path, bytes: item.size,
                generate: { file, done in
                    Self.generate(item, from: file, size: size, scale: scale) { image in deliver(image, true); done() }
                },
                failed: { attributed in deliver(nil, attributed) }))
            return nil
        }
        // Extracted, but it no longer checks out — a link replaced since: read
        // nothing at all.
        guard let contentURL = item.publishedContentURL else { deliver(nil, true); return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            guard item.publishedContentURL == contentURL else { deliver(nil, true); return }
            Self.generate(item, from: contentURL, size: size, scale: scale) { image in
                deliver(item.publishedContentURL == contentURL ? image : nil, true)
            }
        }
        return nil
    }

    /// Withdraws one cell's interest. When nobody else waits for the image, a
    /// request not yet sent is dropped; one already being made runs on and is
    /// kept in the cache.
    func cancel(_ token: ThumbnailToken) {
        guard let k = keyOfToken.removeValue(forKey: ObjectIdentifier(token)) else { return }
        pending[k]?.removeAll { $0.token === token }
        guard pending[k]?.isEmpty == true else { return }
        if ArchiveThumbnailQueue.shared.withdraw(key: k) { pending[k] = nil }
    }

    /// Text is drawn here; everything else goes to the platform thumbnailer.
    private static func generate(_ item: FileItem, from file: URL, size: CGFloat, scale: CGFloat,
                                 completion: @escaping (NSImage?) -> Void) {
        if TextThumbnailRenderer.supports(item),
           let snippet = TextThumbnailRenderer.readSnippet(from: file),
           let image = TextThumbnailRenderer.render(text: snippet.text, size: size, scale: scale) {
            completion(image)
            return
        }
        // Rich documents, images and unsupported text encodings retain the
        // platform thumbnail provider and its existing fallback.
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        request.iconMode = false
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            if let image {
                let dimensions = image.size
                let factor = min(size / max(dimensions.width, 1), size / max(dimensions.height, 1))
                image.size = NSSize(width: dimensions.width * factor, height: dimensions.height * factor)
            }
            completion(image)
        }
    }

    func isCachedForTesting(_ item: FileItem, size: CGFloat, scale: CGFloat) -> Bool {
        cache.object(forKey: Self.cacheKey(for: item, size: size, scale: scale) as NSString) != nil
    }
    func isUnsupportedForTesting(_ item: FileItem, size: CGFloat, scale: CGFloat) -> Bool {
        unsupported.contains(Self.cacheKey(for: item, size: size, scale: scale))
    }
}
