import AppKit
import QuickLookThumbnailing

/// Content previews: readable text excerpts and platform Quick Look images.
/// Generated lazily and cached by path, point size, display scale and file
/// modification stamp, with concurrent requests for the same image coalesced.
final class ThumbnailProvider {

    typealias Loader = (FileItem, CGFloat, CGFloat, @escaping (NSImage?) -> Void) -> NSImage?

    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    /// Files whose type has no thumbnailer — remembered so they are not retried on every scroll.
    private var unsupported = Set<String>()

    private init() { cache.countLimit = 3000 }

    static func canPreview(_ item: FileItem) -> Bool {
        !item.isNavigable && !item.isPackage && item.publishedContentURL != nil
    }

    static func cacheKey(for item: FileItem, size: CGFloat, scale: CGFloat) -> String {
        "\(item.contentURL.path)|\(size)|\(scale)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|\(item.size)"
    }

    /// Returns a cached thumbnail at once, otherwise nil and calls back later on
    /// the main thread (with nil if the file has no preview).
    @discardableResult
    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat,
                   completion: @escaping (NSImage?) -> Void) -> NSImage? {
        guard Self.canPreview(item), let contentURL = item.publishedContentURL else { return nil }
        let k = Self.cacheKey(for: item, size: size, scale: scale)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if unsupported.contains(k) { return nil }
        if pending[k] != nil { pending[k]!.append(completion); return nil }
        pending[k] = [completion]

        let deliver: (NSImage?) -> Void = { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                let image = item.publishedContentURL == contentURL ? image : nil
                if let image { self.cache.setObject(image, forKey: k as NSString) } else { self.unsupported.insert(k) }
                let callbacks = self.pending.removeValue(forKey: k) ?? []
                callbacks.forEach { $0(image) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if TextThumbnailRenderer.supports(item),
               let safeURL = item.publishedContentURL, safeURL == contentURL,
               let snippet = TextThumbnailRenderer.readSnippet(from: safeURL),
               let image = TextThumbnailRenderer.render(text: snippet.text, size: size, scale: scale) {
                deliver(image)
                return
            }
            // Rich documents, images and unsupported text encodings retain
            // the platform thumbnail provider and its existing fallback.
            guard item.publishedContentURL == contentURL else { deliver(nil); return }
            let request = QLThumbnailGenerator.Request(fileAt: contentURL, size: CGSize(width: size, height: size),
                                                       scale: scale, representationTypes: .thumbnail)
            request.iconMode = false
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                let image = rep?.nsImage
                if let image {
                    let dimensions = image.size
                    let factor = min(size / max(dimensions.width, 1), size / max(dimensions.height, 1))
                    image.size = NSSize(width: dimensions.width * factor, height: dimensions.height * factor)
                }
                deliver(image)
            }
        }
        return nil
    }
}
