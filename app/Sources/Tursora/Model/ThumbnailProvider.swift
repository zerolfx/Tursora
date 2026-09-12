import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails ("previews" in Dolphin's terms): what a file looks
/// like, not what type it is. Generated lazily for whatever the views show,
/// cached by path + size + modification stamp, requests coalesced.
final class ThumbnailProvider {

    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    /// Files whose type has no thumbnailer — remembered so they are not retried on every scroll.
    private var unsupported = Set<String>()

    private init() { cache.countLimit = 3000 }

    static func canPreview(_ item: FileItem) -> Bool {
        !item.isNavigable && !item.isPackage && item.readableContentURL != nil
    }

    private func key(_ item: FileItem, _ size: CGFloat) -> String {
        "\(item.contentURL.path)|\(Int(size))|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|\(item.size)"
    }

    /// Returns a cached thumbnail at once, otherwise nil and calls back later on
    /// the main thread (with nil if the file has no preview).
    @discardableResult
    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat,
                   completion: @escaping (NSImage?) -> Void) -> NSImage? {
        guard Self.canPreview(item), let contentURL = item.readableContentURL else { return nil }
        let k = key(item, size)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if unsupported.contains(k) { return nil }
        if pending[k] != nil { pending[k]!.append(completion); return nil }
        pending[k] = [completion]

        let request = QLThumbnailGenerator.Request(fileAt: contentURL, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        request.iconMode = false
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            if let image {
                // Points, fitted inside the requested square, aspect preserved.
                let s = image.size
                let f = min(size / max(s.width, 1), size / max(s.height, 1))
                image.size = NSSize(width: s.width * f, height: s.height * f)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let image = item.readableContentURL == contentURL ? image : nil
                if let image { self.cache.setObject(image, forKey: k as NSString) } else { self.unsupported.insert(k) }
                let callbacks = self.pending.removeValue(forKey: k) ?? []
                callbacks.forEach { $0(image) }
            }
        }
        return nil
    }
}
