import AppKit
import CoreText
import Darwin
import UniformTypeIdentifiers

/// Text icons show a readable leading excerpt instead of shrinking a complete
/// document page. Reads and layout are bounded, and never run in a file view.
enum TextThumbnailRenderer {
    static let maxReadBytes = 65_536
    static let maxLayoutCharacters = 8_192

    struct Snippet {
        let text: String
        let bytesRead: Int
    }

    struct Layout {
        let pageSize: NSSize
        let fontSize: CGFloat
        let padding: CGFloat
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func supports(_ item: FileItem) -> Bool {
        guard ThumbnailProvider.canPreview(item) else { return false }
        return isTextType(item.contentType ?? UTType(filenameExtension: item.url.pathExtension),
                          pathExtension: item.url.pathExtension)
    }

    /// Whether this renderer draws a file of this type, from the type alone.
    static func isTextType(_ type: UTType?, pathExtension: String) -> Bool {
        if let type, type.conforms(to: .plainText) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .xml) { return true }
        return ["md", "markdown", "yaml", "yml", "toml", "ini", "log"].contains(pathExtension.lowercased())
    }

    /// `limit` caps the characters returned. The default is the icon
    /// budget; the preview pane asks for far more of the file.
    static func readSnippet(from url: URL, limit: Int = maxLayoutCharacters) -> Snippet? {
        guard url.isFileURL else { return nil }
        // Opening a FIFO normally blocks before a file handle can inspect it.
        // Nonblocking open followed by fstat also rejects replacement devices.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        var bytes = [UInt8](repeating: 0, count: max(maxReadBytes, min(limit * 4, 2_097_152)))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        let data = Data(bytes.prefix(count))
        guard let text = decode(data, isTruncated: metadata.st_size > off_t(count)) else { return nil }
        let excerpt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return nil }
        return Snippet(text: String(excerpt.prefix(limit)), bytesRead: count)
    }

    static func decode(_ data: Data, isTruncated: Bool = false) -> String? {
        var bytes = Array(data)
        let text: String?
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            let littleEndian = bytes[0] == 0xff
            bytes.removeFirst(2)
            if bytes.count % 2 != 0 {
                guard isTruncated else { return nil }
                bytes.removeLast()
            }
            var units = stride(from: 0, to: bytes.count, by: 2).map { index -> UInt16 in
                let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
                return littleEndian ? first | second << 8 : first << 8 | second
            }
            if isTruncated, let last = units.last, (0xd800...0xdbff).contains(last) { units.removeLast() }
            var index = 0
            while index < units.count {
                let unit = units[index]
                if (0xd800...0xdbff).contains(unit) {
                    guard index + 1 < units.count, (0xdc00...0xdfff).contains(units[index + 1]) else { return nil }
                    index += 2
                } else {
                    guard !(0xdc00...0xdfff).contains(unit) else { return nil }
                    index += 1
                }
            }
            text = String(decoding: units, as: UTF16.self)
        } else {
            if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
            var decoded = String(bytes: bytes, encoding: .utf8)
            // A bounded read can split the final Unicode scalar. Only repair
            // an incomplete suffix; invalid bytes in the body remain rejected.
            if decoded == nil, isTruncated {
                for removed in 1...min(3, bytes.count) {
                    let prefix = bytes.dropLast(removed)
                    let suffix = bytes.suffix(removed)
                    guard let lead = suffix.first,
                          (0xc2...0xf4).contains(lead),
                          suffix.dropFirst().allSatisfy({ (0x80...0xbf).contains($0) }) else { continue }
                    if suffix.count > 1 {
                        let second = suffix[suffix.index(after: suffix.startIndex)]
                        if (lead == 0xe0 && second < 0xa0) || (lead == 0xed && second > 0x9f)
                            || (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second > 0x8f) { continue }
                    }
                    let expected = lead < 0xe0 ? 2 : (lead < 0xf0 ? 3 : 4)
                    if removed < expected, let valid = String(bytes: prefix, encoding: .utf8) {
                        decoded = valid
                        break
                    }
                }
            }
            text = decoded
        }
        guard let text, !text.unicodeScalars.contains(where: {
            ($0.value < 0x20 && ![9, 10, 13].contains($0.value)) || $0.value == 0x7f
        }) else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func layout(size: CGFloat, scale: CGFloat) -> Layout {
        let height = size.isFinite ? min(1_024, max(1, size)) : 64
        let density = scale.isFinite ? min(4, max(1, scale)) : 1
        let page = NSSize(width: max(1, floor(height * 0.75)), height: height)
        let padding = max(3, floor(height / 16))
        return Layout(pageSize: page, fontSize: min(10, max(7, (height - 2 * padding) / 16)),
                      padding: padding, pixelWidth: Int(ceil(page.width * density)),
                      pixelHeight: Int(ceil(page.height * density)))
    }

    static func render(text: String, size: CGFloat, scale: CGFloat) -> NSImage? {
        let geometry = layout(size: size, scale: scale)
        guard let context = CGContext(data: nil, width: geometry.pixelWidth, height: geometry.pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(geometry.pixelWidth) / geometry.pageSize.width,
                        y: CGFloat(geometry.pixelHeight) / geometry.pageSize.height)
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(origin: .zero, size: geometry.pageSize))
        context.setStrokeColor(CGColor(gray: 0.80, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(CGRect(origin: .zero, size: geometry.pageSize).insetBy(dx: 0.25, dy: 0.25))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.tabStops = []
        paragraph.defaultTabInterval = geometry.fontSize * 2.4
        let font = CTFontCreateWithName("Menlo" as CFString, geometry.fontSize, nil)
        let excerpt = String(text.prefix(maxLayoutCharacters)).trimmingCharacters(in: .newlines)
        let attributed = NSAttributedString(string: excerpt, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.10, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let frameRect = CGRect(origin: .zero, size: geometry.pageSize).insetBy(dx: geometry.padding, dy: geometry.padding)
        if frameRect.width > 0, frameRect.height > 0 {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                CGPath(rect: frameRect, transform: nil), nil)
            context.saveGState()
            context.clip(to: frameRect)
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: geometry.pageSize)
    }
}
