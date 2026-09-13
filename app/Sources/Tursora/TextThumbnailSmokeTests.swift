import AppKit
import Darwin

/// Text decoding and real thumbnail consumers, including deliberately reversed
/// completion order so asynchronous regressions do not depend on timing.
enum TextThumbnailSmokeTests: SmokeSuite {
    static let checkPrefix = "text thumbnails: "
    static func run(completion: @escaping () -> Void) {
        Task { @MainActor in
            await runChecks()
            completion()
        }
    }

    @MainActor private static func runChecks() async {
        print("== text thumbnails ==")
        decoding()
        rendering()
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("tursora-text-thumbnails-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: fixture) }
            let url = fixture.appendingPathComponent("notes.txt")
            let text = "Project Mercury\nActual readable content\n中文和 emoji 🚀\n"
            try Data(text.utf8).write(to: url)
            let item = FileItem(url: url)!
            check("plain text is supported", TextThumbnailRenderer.supports(item))
            check("directory does not become a text thumbnail", !TextThumbnailRenderer.supports(FileItem(url: fixture)!))
            let snippet = TextThumbnailRenderer.readSnippet(from: url)
            check("file reader preserves real Unicode content", snippet?.text == text.trimmingCharacters(in: .whitespacesAndNewlines))
            check("file reader reports actual bytes", snippet?.bytesRead == text.utf8.count)

            let largeURL = fixture.appendingPathComponent("large.txt")
            try Data(String(repeating: "a", count: TextThumbnailRenderer.maxReadBytes + 100).utf8).write(to: largeURL)
            let large = TextThumbnailRenderer.readSnippet(from: largeURL)
            check("large file read stays within byte budget", large?.bytesRead == TextThumbnailRenderer.maxReadBytes)
            check("layout excerpt stays bounded", large?.text.count == 8_192)
            let empty = fixture.appendingPathComponent("empty.txt")
            try Data(" \n\t".utf8).write(to: empty)
            check("whitespace-only files retain the ordinary icon fallback", TextThumbnailRenderer.readSnippet(from: empty) == nil)
            let binary = fixture.appendingPathComponent("binary.txt")
            try Data([0x61, 0x00, 0x62]).write(to: binary)
            check("text extension cannot disguise binary content", TextThumbnailRenderer.readSnippet(from: binary) == nil)
            check("directory reader rejects nonregular content", TextThumbnailRenderer.readSnippet(from: fixture) == nil)
            let fifo = fixture.appendingPathComponent("pipe.txt")
            check("FIFO fixture created", mkfifo(fifo.path, mode_t(0o600)) == 0)
            let before = ProcessInfo.processInfo.systemUptime
            check("FIFO is rejected without waiting for a writer", TextThumbnailRenderer.readSnippet(from: fifo) == nil
                  && ProcessInfo.processInfo.systemUptime - before < 1)
            let alias = fixture.appendingPathComponent("alias.txt")
            try fm.createSymbolicLink(at: alias, withDestinationURL: url)
            check("regular-file symlink uses target content", TextThumbnailRenderer.readSnippet(from: alias)?.text == snippet?.text)

            let smallKey = ThumbnailProvider.cacheKey(for: item, size: 64, scale: 1)
            check("cache differentiates display density", smallKey != ThumbnailProvider.cacheKey(for: item, size: 64, scale: 2))
            check("cache differentiates icon dimensions", smallKey != ThumbnailProvider.cacheKey(for: item, size: 256, scale: 1))
            let otherURL = fixture.appendingPathComponent("other.txt")
            try Data("Other content".utf8).write(to: otherURL)
            let other = FileItem(url: otherURL)!
            check("cache differentiates file identity", smallKey != ThumbnailProvider.cacheKey(for: other, size: 64, scale: 1))
            consumerRaces(item: item, other: other)
            backingScaleRaces(item: item)
            await provider(item: item)
        } catch {
            try? fm.removeItem(at: fixture)
            check("fixture operations succeed: \(error)", false)
        }
    }

    private static func decoding() {
        let unicode = "中文 🚀\n  indented\tvalue"
        check("UTF-8 retains text and indentation", TextThumbnailRenderer.decode(Data(unicode.utf8)) == unicode)
        check("UTF-8 BOM and line endings normalize", TextThumbnailRenderer.decode(Data([0xef, 0xbb, 0xbf]) + Data("A\r\nB\rC".utf8)) == "A\nB\nC")
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let bom: [UInt8] = encoding == .utf16LittleEndian ? [0xff, 0xfe] : [0xfe, 0xff]
            let data = Data(bom) + unicode.data(using: encoding)!
            check("UTF-16 \(encoding.rawValue) decodes CJK and surrogate pairs", TextThumbnailRenderer.decode(data) == unicode)
        }
        for scalar in ["é", "中", "🚀"] {
            let bytes = Array(scalar.utf8)
            for count in 1..<bytes.count {
                let prefix = Data("Valid ".utf8) + Data(bytes.prefix(count))
                check("bounded UTF-8 \(bytes.count)-byte scalar suffix \(count) preserves prefix", TextThumbnailRenderer.decode(prefix, isTruncated: true) == "Valid ")
                check("unbounded incomplete UTF-8 is invalid", TextThumbnailRenderer.decode(prefix) == nil)
            }
        }
        check("invalid UTF-8 body is not repaired as truncation", TextThumbnailRenderer.decode(Data([0x61, 0xff, 0x62, 0xe4]), isTruncated: true) == nil)
        check("overlong UTF-8 prefix is rejected", TextThumbnailRenderer.decode(Data([0x61, 0xe0, 0x80]), isTruncated: true) == nil)
        check("UTF-16 bounded high surrogate is removed", TextThumbnailRenderer.decode(Data([0xff, 0xfe, 0x41, 0x00, 0x3d, 0xd8]), isTruncated: true) == "A")
        check("UTF-16 bounded half code unit is removed", TextThumbnailRenderer.decode(Data([0xfe, 0xff, 0x00, 0x41, 0x4e]), isTruncated: true) == "A")
        check("UTF-16 incomplete scalar at EOF is invalid", TextThumbnailRenderer.decode(Data([0xff, 0xfe, 0x41, 0x00, 0x3d, 0xd8])) == nil)
        check("UTF-16 orphan low surrogate is invalid", TextThumbnailRenderer.decode(Data([0xff, 0xfe, 0x00, 0xdc]), isTruncated: true) == nil)
        check("BOM-only text decodes as empty", TextThumbnailRenderer.decode(Data([0xef, 0xbb, 0xbf])) == "")
        check("binary controls are rejected after decoding", TextThumbnailRenderer.decode(Data([0xff, 0xfe, 0x41, 0x00, 0x00, 0x00])) == nil)
    }

    private static func rendering() {
        for size: CGFloat in [64, 128, 256, 512] {
            let one = TextThumbnailRenderer.layout(size: size, scale: 1)
            let two = TextThumbnailRenderer.layout(size: size, scale: 2)
            check("\(Int(size))pt thumbnail has a portrait page", abs(one.pageSize.width / one.pageSize.height - 0.75) < 0.01)
            check("\(Int(size))pt density changes pixels without changing layout", one.pageSize == two.pageSize
                  && one.fontSize == two.fontSize && two.pixelWidth == one.pixelWidth * 2 && two.pixelHeight == one.pixelHeight * 2)
            guard let image = TextThumbnailRenderer.render(text: "Actual text\n中文 🚀", size: size, scale: 2),
                  let bitmap = bitmap(image) else { check("\(Int(size))pt image renders", false); continue }
            check("\(Int(size))pt image retains logical size and exact raster density", image.size == two.pageSize
                  && bitmap.pixelsWide == two.pixelWidth && bitmap.pixelsHigh == two.pixelHeight)
        }
        let first = TextThumbnailRenderer.render(text: "IIIIIIII", size: 128, scale: 2)!
        let second = TextThumbnailRenderer.render(text: "WWWWWWWW", size: 128, scale: 2)!
        check("equal-length text produces different actual glyph pixels", first.tiffRepresentation != second.tiffRepresentation)
        let blank = TextThumbnailRenderer.render(text: "", size: 128, scale: 2)!
        let content = TextThumbnailRenderer.render(text: "中文 🚀", size: 128, scale: 2)!
        check("Unicode content changes the page image", blank.tiffRepresentation != content.tiffRepresentation)
        let capped = TextThumbnailRenderer.render(text: String(repeating: "W", count: 8_192), size: 128, scale: 2)!
        let longer = TextThumbnailRenderer.render(text: String(repeating: "W", count: 20_000), size: 128, scale: 2)!
        check("long unbroken content stays within bounded layout", capped.tiffRepresentation == longer.tiffRepresentation)
    }

    @MainActor private static func consumerRaces(item: FileItem, other: FileItem) {
        let model = DirectoryModel(provider: LocalFileProvider())
        model.beginSearchResults()
        model.replaceSearchResults([item])
        let small = NSImage(size: NSSize(width: 48, height: 64))
        let large = NSImage(size: NSSize(width: 192, height: 256))
        var gridPending: [(NSImage?) -> Void] = []
        let grid = IconGridViewController(model: model)
        grid.thumbnailLoader = { _, _, _, callback in gridPending.append(callback); return nil }
        _ = grid.view
        grid.reloadData()
        let path = IndexPath(item: 0, section: 0)
        func gridCell() -> FileCollectionItem {
            grid.collectionView(grid.collectionView, itemForRepresentedObjectAt: path) as! FileCollectionItem
        }
        let oldGrid = gridCell()
        let oldGridReply = gridPending.last!
        grid.setIconSize(256, showPreviews: true)
        let newGrid = gridCell()
        gridPending.last!(large)
        let oldGridImage = oldGrid.iconView.image
        oldGridReply(small)
        check("grid late small request cannot overwrite after zoom", newGrid.iconView.image === large && oldGrid.iconView.image === oldGridImage)
        let offGrid = gridCell()
        let offGridReply = gridPending.last!
        grid.setIconSize(256, showPreviews: false)
        let beforeOffGrid = offGrid.iconView.image
        offGridReply(small)
        check("grid disabled previews reject pending results", offGrid.iconView.image === beforeOffGrid)
        grid.setIconSize(256, showPreviews: true)
        let reusedGrid = gridCell()
        let reuseGridReply = gridPending.last!
        reusedGrid.configure(item: other, iconSize: 256, faded: false)
        let replacement = reusedGrid.iconView.image
        reuseGridReply(small)
        check("grid reconfigured cell rejects an earlier request token", reusedGrid.iconView.image === replacement)

        var listPending: [(NSImage?) -> Void] = []
        let list = FileListViewController(model: model)
        list.thumbnailLoader = { _, _, _, callback in listPending.append(callback); return nil }
        _ = list.view
        list.setIconSize(32, showPreviews: true)
        let nameColumn = list.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))!
        func listCell() -> NSTableCellView {
            list.outlineView(list.tableView, viewFor: nameColumn, item: model.nodes[0]) as! NSTableCellView
        }
        let oldList = listCell()
        let oldListReply = listPending.last!
        list.setIconSize(64, showPreviews: true)
        let newList = listCell()
        listPending.last!(large)
        let oldListImage = oldList.imageView?.image
        oldListReply(small)
        check("list late small request cannot overwrite after zoom", newList.imageView?.image === large && oldList.imageView?.image === oldListImage)
        let offList = listCell()
        let offListReply = listPending.last!
        list.setIconSize(64, showPreviews: false)
        let beforeOffList = offList.imageView?.image
        offListReply(small)
        check("list disabled previews reject pending results", offList.imageView?.image === beforeOffList)
        list.setIconSize(64, showPreviews: true)
        let reusedList = listCell()
        let reuseListReply = listPending.last!
        reusedList.objectValue = UUID()
        let beforeReuseList = reusedList.imageView?.image
        reuseListReply(small)
        check("list invalidated cell token rejects an earlier callback", reusedList.imageView?.image === beforeReuseList)
    }

    /// Exercise AppKit's backing-property notification on attached consumers,
    /// without requiring physical monitors with two different pixel densities.
    @MainActor private static func backingScaleRaces(item: FileItem) {
        let model = DirectoryModel(provider: LocalFileProvider())
        model.beginSearchResults()
        model.replaceSearchResults([item])
        let window = ScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let oldImage = NSImage(size: NSSize(width: 48, height: 64))
        let newImage = NSImage(size: NSSize(width: 96, height: 128))
        var gridRequests: [(scale: CGFloat, reply: (NSImage?) -> Void)] = []
        let grid = IconGridViewController(model: model)
        grid.thumbnailLoader = { _, _, scale, reply in gridRequests.append((scale, reply)); return nil }
        window.contentView = grid.view
        grid.reloadData()
        let path = IndexPath(item: 0, section: 0)
        func gridCell() -> FileCollectionItem {
            grid.collectionView(grid.collectionView, itemForRepresentedObjectAt: path) as! FileCollectionItem
        }
        let firstGrid = gridCell()
        let firstGridRequest = gridRequests.last!
        check("attached grid requests the first display density", firstGridRequest.scale == 1)
        var gridChanges = 0
        let originalGridChange = grid.collectionView.onBackingScaleChanged
        grid.collectionView.onBackingScaleChanged = { gridChanges += 1; originalGridChange?() }
        window.simulatedScale = 2
        grid.collectionView.viewDidChangeBackingProperties()
        check("grid backing change reaches the controller reload hook", gridChanges == 1)
        grid.collectionView.viewDidChangeBackingProperties()
        check("unchanged grid density does not trigger duplicate reloads", gridChanges == 1)
        grid.view.layoutSubtreeIfNeeded()
        let secondGrid = gridCell()
        let secondGridRequest = gridRequests.last!
        check("grid after display change requests the new density", secondGridRequest.scale == 2)
        secondGridRequest.reply(newImage)
        let firstGridBaseline = firstGrid.iconView.image
        firstGridRequest.reply(oldImage)
        check("grid display change rejects the old-density callback", firstGrid.iconView.image === firstGridBaseline
              && secondGrid.iconView.image === newImage)
        grid.setIconSize(64, showPreviews: false)
        let gridCount = gridRequests.count
        window.simulatedScale = 1
        grid.collectionView.viewDidChangeBackingProperties()
        grid.view.layoutSubtreeIfNeeded()
        _ = gridCell()
        check("grid density change keeps disabled previews disabled", gridRequests.count == gridCount)

        var listRequests: [(scale: CGFloat, reply: (NSImage?) -> Void)] = []
        let list = FileListViewController(model: model)
        list.thumbnailLoader = { _, _, scale, reply in listRequests.append((scale, reply)); return nil }
        window.contentView = list.view
        list.setIconSize(64, showPreviews: true)
        let nameColumn = list.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))!
        func listCell() -> NSTableCellView {
            list.outlineView(list.tableView, viewFor: nameColumn, item: model.nodes[0]) as! NSTableCellView
        }
        let firstList = listCell()
        let firstListRequest = listRequests.last!
        check("attached list requests the first display density", firstListRequest.scale == 1)
        var listChanges = 0
        let originalListChange = list.tableView.onBackingScaleChanged
        list.tableView.onBackingScaleChanged = { listChanges += 1; originalListChange?() }
        window.simulatedScale = 2
        list.tableView.viewDidChangeBackingProperties()
        check("list backing change reaches the controller reload hook", listChanges == 1)
        list.tableView.viewDidChangeBackingProperties()
        check("unchanged list density does not trigger duplicate reloads", listChanges == 1)
        list.view.layoutSubtreeIfNeeded()
        let secondList = listCell()
        let secondListRequest = listRequests.last!
        check("list after display change requests the new density", secondListRequest.scale == 2)
        secondListRequest.reply(newImage)
        let firstListBaseline = firstList.imageView?.image
        firstListRequest.reply(oldImage)
        check("list display change rejects the old-density callback", firstList.imageView?.image === firstListBaseline
              && secondList.imageView?.image === newImage)
        list.setIconSize(64, showPreviews: false)
        let listCount = listRequests.count
        window.simulatedScale = 1
        list.tableView.viewDidChangeBackingProperties()
        list.view.layoutSubtreeIfNeeded()
        _ = listCell()
        check("list density change keeps disabled previews disabled", listRequests.count == listCount)
    }

    private final class ScaleWindow: NSWindow {
        var simulatedScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { simulatedScale }
    }

    @MainActor private static func provider(item: FileItem) async {
        var images: [NSImage?] = []
        var allOnMain = true
        let callback: (NSImage?) -> Void = { image in images.append(image); allOnMain = allOnMain && Thread.isMainThread }
        let first = ThumbnailProvider.shared.thumbnail(for: item, size: 128, scale: 2, completion: callback)
        let second = ThumbnailProvider.shared.thumbnail(for: item, size: 128, scale: 2, completion: callback)
        check("uncached duplicate requests are asynchronous", first == nil && second == nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while images.count < 2 && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check("coalesced text requests both complete on main", images.count == 2 && images.allSatisfy { $0 != nil } && allOnMain)
        var calledSynchronously = false
        let hit = ThumbnailProvider.shared.thumbnail(for: item, size: 128, scale: 2) { _ in calledSynchronously = true }
        check("completed text thumbnail is returned from cache", hit != nil && !calledSynchronously)
        if let hit, let pixels = bitmap(hit) {
            check("provider returns the requested Retina text raster", hit.size == NSSize(width: 96, height: 128)
                  && pixels.pixelsWide == 192 && pixels.pixelsHigh == 256)
        } else { check("cached text raster is available", false) }
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }
}
