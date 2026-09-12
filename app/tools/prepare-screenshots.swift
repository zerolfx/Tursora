#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

// Remove a white matte from the measured exterior of a dark window capture.
// This is not a rounded-rectangle mask. Only four disconnected corner floods
// and their narrow edge bands are editable; all other decoded pixels must
// survive PNG encoding unchanged. JPEG flattening loses the original alpha,
// so edge coverage is estimated from nearby opaque colors, never claimed exact.
// Existing transparent PNGs are copied byte-for-byte, without re-encoding.
// --mask-from is only for a caller-verified, registered light/dark capture pair
// of the exact same window frame. Matching dimensions cannot prove alignment.

enum PreparationError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PreparationError.invalid(message) }
}
func resolvedFileLocation(_ url: URL) -> URL {
    // Foundation does not resolve a missing leaf through a symlinked parent.
    // Resolve the existing parent first, then the leaf if it already exists.
    url.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath()
}

struct Bitmap {
    let image: CGImage
    let width: Int
    let height: Int
    var pixels: [UInt8] // Straight RGBA in the source image's color space.

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let providerData = image.dataProvider?.data else {
            throw PreparationError.invalid("Input must be one decodable, still image.")
        }
        try require(image.width >= 128 && image.height >= 128 && image.width <= 12000 && image.height <= 12000,
                    "Unsupported dimensions; expected a bounded window screenshot.")
        try require(image.width * image.height <= 60_000_000, "Screenshot exceeds the 60 MP memory limit.")
        try require(image.bitsPerComponent == 8 && [24, 32].contains(image.bitsPerPixel)
                    && image.colorSpace?.model == .rgb, "Only 8-bit RGB screenshots are supported; no color conversion is performed.")
        self.image = image
        width = image.width
        height = image.height
        let raw = providerData as Data
        let stride = image.bitsPerPixel / 8
        let littleEndian = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let alpha = image.alphaInfo
        let first = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
        let premultiplied = [.premultipliedFirst, .premultipliedLast].contains(alpha)
        try require(raw.count >= image.bytesPerRow * height, "Incomplete decoded image buffer.")
        pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * image.bytesPerRow + x * stride
                let target = (y * width + x) * 4
                var components = Array(raw[source..<(source + stride)])
                if stride == 4 && littleEndian { components.reverse() }
                let colorOffset = stride == 4 && first ? 1 : 0
                let a = hasAlpha ? components[first ? 0 : 3] : 255
                for c in 0..<3 {
                    let value = components[colorOffset + c]
                    pixels[target + c] = premultiplied && a > 0
                        ? UInt8(min(255, (Int(value) * 255 + Int(a) / 2) / Int(a))) : value
                }
                pixels[target + 3] = a
            }
        }
    }

    func makeImage(pixels: [UInt8]) throws -> CGImage {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: image.colorSpace!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                        .union(.byteOrder32Big),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: image.renderingIntent) else {
            throw PreparationError.invalid("Could not construct a PNG bitmap.")
        }
        return result
    }
}

struct Corner {
    let name: String
    let right: Bool
    let bottom: Bool
    func index(_ x: Int, _ y: Int, in bitmap: Bitmap) -> Int {
        let globalX = right ? bitmap.width - 1 - x : x
        let globalY = bottom ? bitmap.height - 1 - y : y
        return globalY * bitmap.width + globalX
    }
}
let corners = [Corner(name: "top-left", right: false, bottom: false),
               Corner(name: "top-right", right: true, bottom: false),
               Corner(name: "bottom-left", right: false, bottom: true),
               Corner(name: "bottom-right", right: true, bottom: true)]

func rgb(_ bitmap: Bitmap, _ index: Int) -> [Double] {
    (0..<3).map { Double(bitmap.pixels[index * 4 + $0]) }
}
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
func average(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
func isMatte(_ values: [Double]) -> Bool {
    values.min()! >= 235 && average(values) >= 245 && values.max()! - values.min()! <= 24
}

// Locate an observed, locally flat opaque run on an outer scanline. This
// determines the corner's reach, including the long one-pixel antialias tail
// left by downsampling; it does not fit a radius or cut the window to a shape.
func stableRun(bitmap: Bitmap, corner: Corner, horizontal: Bool, offset: Int, limit: Int) throws -> (start: Int, color: [Double]) {
    let length = 7
    for start in 3..<(limit - length - 3) {
        let samples = (start..<(start + length)).map { value in
            rgb(bitmap, corner.index(horizontal ? value : offset, horizontal ? offset : value, in: bitmap))
        }
        let color = (0..<3).map { channel in median(samples.map { $0[channel] }) }
        let stable = (0..<3).allSatisfy { channel in
            let values = samples.map { $0[channel] }
            return values.max()! - values.min()! <= 12
        }
        if stable && average(color) < 205 { return (start, color) }
    }
    throw PreparationError.invalid("\(corner.name): no dark, stable outer edge before the safety limit; use an original alpha capture.")
}

struct Prepared {
    let pixels: [UInt8]
    let changed: Set<Int>
    let records: [[String: Any]]
    let limit: Int
}

func prepare(_ bitmap: Bitmap) throws -> Prepared {
    try require(stride(from: 3, to: bitmap.pixels.count, by: 4).allSatisfy { bitmap.pixels[$0] == 255 },
                "Mixed existing alpha is not a white-matte capture; preserve or recapture it instead.")
    let limit = min(192, max(48, Int(Double(min(bitmap.width, bitmap.height)) * 0.15)))
    try require(limit * 2 < min(bitmap.width, bitmap.height), "Corner safety regions would overlap.")
    var output = bitmap.pixels
    var changed = Set<Int>()
    var records: [[String: Any]] = []
    var extents: [Int] = []

    for corner in corners {
        let previouslyChanged = changed
        try require(isMatte(rgb(bitmap, corner.index(0, 0, in: bitmap))),
                    "\(corner.name): outermost pixel is not a near-white matte; refusing to infer a window outline.")
        let top = try stableRun(bitmap: bitmap, corner: corner, horizontal: true, offset: 0, limit: limit)
        let side = try stableRun(bitmap: bitmap, corner: corner, horizontal: false, offset: 0, limit: limit)
        let spanX = top.start + 7
        let spanY = side.start + 7
        extents += [spanX, spanY]
        var flood = Set<Int>([0])
        var queue = [0]
        var head = 0
        while head < queue.count {
            let local = queue[head]
            head += 1
            let x = local % limit, y = local / limit
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0 && ny >= 0 && nx < limit && ny < limit else { continue }
                let next = ny * limit + nx
                if !flood.contains(next), isMatte(rgb(bitmap, corner.index(nx, ny, in: bitmap))) {
                    flood.insert(next)
                    queue.append(next)
                }
            }
        }
        try require(flood.count >= 4, "\(corner.name): insufficient connected white exterior.")
        try require(!flood.contains { $0 % limit >= limit - 4 || $0 / limit >= limit - 4 },
                    "\(corner.name): the white flood reaches the safety boundary, possibly into light window content.")
        try require(!flood.contains { $0 % limit >= spanX || $0 / limit >= spanY },
                    "\(corner.name): white exterior extends beyond the measured opaque edges.")

        var band = Set<Int>()
        for local in flood {
            let x = local % limit, y = local / limit
            for dy in -2...2 {
                for dx in -2...2 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0 && ny >= 0 && nx < spanX && ny < spanY {
                        band.insert(ny * limit + nx)
                    }
                }
            }
        }
        // The outside of the image is also exterior. Include only the measured
        // corner tails along its first two rows/columns, not the full perimeter.
        for x in 0..<spanX { for y in 0..<2 { band.insert(y * limit + x) } }
        for y in 0..<spanY { for x in 0..<2 { band.insert(y * limit + x) } }
        var feathered = 0
        var transparent = 0

        for local in band.sorted() {
            let x = local % limit, y = local / limit
            let global = corner.index(x, y, in: bitmap)
            let byte = global * 4
            if flood.contains(local) {
                output.replaceSubrange(byte..<(byte + 4), with: [0, 0, 0, 0])
                changed.insert(global)
                transparent += 1
                continue
            }
            let foreground: [Double]
            if y < 2 && x >= y {
                foreground = try stableRun(bitmap: bitmap, corner: corner, horizontal: true, offset: y, limit: limit).color
            } else if x < 2 {
                foreground = try stableRun(bitmap: bitmap, corner: corner, horizontal: false, offset: x, limit: limit).color
            } else {
                var samples: [[Double]] = []
                for dy in 3...5 { for dx in 3...5 {
                    let candidate = (y + dy) * limit + x + dx
                    if x + dx < limit && y + dy < limit && !band.contains(candidate) {
                        samples.append(rgb(bitmap, corner.index(x + dx, y + dy, in: bitmap)))
                    }
                } }
                try require(!samples.isEmpty, "\(corner.name): no protected pixels for edge estimation.")
                foreground = (0..<3).map { c in median(samples.map { $0[c] }) }
            }
            let color = rgb(bitmap, global)
            // Leave opaque pixels and ordinary JPEG noise untouched.
            guard average(color) - average(foreground) > 9 else { continue }
            let distance = foreground.map { 255 - $0 }
            let denominator = distance.reduce(0) { $0 + $1 * $1 }
            try require(average(foreground) < 205 && denominator > 7_500,
                        "\(corner.name): insufficient matte/foreground contrast for edge recovery.")
            let alpha = zip(distance, color).reduce(0) { $0 + $1.0 * (255 - $1.1) } / denominator
            guard alpha < 0.985 else { continue }
            let residual = (0..<3).map { abs(color[$0] - (alpha * foreground[$0] + (1 - alpha) * 255)) }.max()!
            try require(residual <= 22 && alpha >= 0,
                        "\(corner.name): colored or inconsistent fringe (residual \(String(format: "%.1f", residual))); refusing to alter it.")
            let alphaByte = max(0, min(254, Int((alpha * 255).rounded())))
            if alphaByte <= 8 {
                output.replaceSubrange(byte..<(byte + 4), with: [0, 0, 0, 0])
                transparent += 1
            } else {
                for c in 0..<3 {
                    // Undo white compositing only in this partial-alpha fringe.
                    let unmatte = (color[c] - Double(255 - alphaByte)) * 255 / Double(alphaByte)
                    output[byte + c] = UInt8(max(0, min(255, Int(unmatte.rounded()))))
                }
                output[byte + 3] = UInt8(alphaByte)
                feathered += 1
            }
            changed.insert(global)
        }
        records.append(["corner": corner.name, "measuredSpan": [spanX, spanY],
                        "connectedMattePixels": flood.count, "transparentPixels": transparent,
                        "antialiasPixels": feathered, "candidateBandPixels": band.count,
                        "changedBounds": bounds(of: changed.subtracting(previouslyChanged), width: bitmap.width) as Any? ?? NSNull()])
    }
    try require(extents.max()! <= extents.min()! * 3,
                "Corner extents differ too much for a single window capture; refusing to normalize them.")
    return Prepared(pixels: output, changed: changed, records: records, limit: limit)
}

func applyRegisteredMask(_ reference: Bitmap, to bitmap: Bitmap) throws -> Prepared {
    try require(reference.width == bitmap.width && reference.height == bitmap.height,
                "Reference mask dimensions must exactly match the source; it is never resized or aligned automatically.")
    try require(stride(from: 3, to: bitmap.pixels.count, by: 4).allSatisfy { bitmap.pixels[$0] == 255 },
                "A registered white-matte source must be fully opaque.")
    let limit = min(192, max(48, Int(Double(min(bitmap.width, bitmap.height)) * 0.15)))
    var output = bitmap.pixels
    var changed = Set<Int>()
    var cornerChanges = Array(repeating: Set<Int>(), count: 4)
    for corner in corners {
        let index = corner.index(0, 0, in: bitmap)
        try require(isMatte(rgb(bitmap, index)) && reference.pixels[index * 4 + 3] == 0,
                    "\(corner.name): registered source needs a white exterior and reference needs a transparent corner.")
    }
    for index in 0..<(bitmap.width * bitmap.height) {
        let alpha = Int(reference.pixels[index * 4 + 3])
        guard alpha < 255 else { continue }
        let x = index % bitmap.width, y = index / bitmap.width
        let localX = min(x, bitmap.width - 1 - x), localY = min(y, bitmap.height - 1 - y)
        try require(localX < limit - 4 && localY < limit - 4,
                    "Reference transparency extends outside the bounded corner regions; refusing a menu or unrelated mask.")
        let source = rgb(bitmap, index), byte = index * 4
        if alpha == 0 {
            try require(isMatte(source), "Reference exterior covers a nonwhite source pixel; the captures may not be registered.")
            output.replaceSubrange(byte..<(byte + 4), with: [0, 0, 0, 0])
        } else {
            for channel in 0..<3 {
                let recovered = (source[channel] - Double(255 - alpha)) * 255 / Double(alpha)
                let value = max(0, min(255, Int(recovered.rounded())))
                let recomposited = Double(value * alpha) / 255 + Double(255 - alpha)
                try require(abs(recomposited - source[channel]) <= 15,
                            "Registered mask cannot explain the source edge over white; verify the exact capture frame.")
                output[byte + channel] = UInt8(value)
            }
            output[byte + 3] = UInt8(alpha)
        }
        changed.insert(index)
        cornerChanges[(y >= bitmap.height / 2 ? 2 : 0) + (x >= bitmap.width / 2 ? 1 : 0)].insert(index)
    }
    let records: [[String: Any]] = corners.enumerated().map { n, corner in
        ["corner": corner.name, "changedPixels": cornerChanges[n].count,
         "changedBounds": bounds(of: cornerChanges[n], width: bitmap.width) as Any? ?? NSNull()]
    }
    return Prepared(pixels: output, changed: changed, records: records, limit: limit)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw PreparationError.invalid("Could not create PNG destination.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "Could not finish PNG encoding.")
}

func bounds(of indices: Set<Int>, width: Int) -> [Int]? {
    guard !indices.isEmpty else { return nil }
    let xs = indices.map { $0 % width }, ys = indices.map { $0 / width }
    return [xs.min()!, ys.min()!, xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1]
}

func contactSheet(original: CGImage, result: CGImage, limit: Int, output: URL) throws {
    let column = 420, overview = 290, crop = min(limit, 90), zoom = 4
    let rowHeight = crop * zoom + 32
    let width = column * 3, height = overview + rowHeight * 4
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw PreparationError.invalid("Could not create QA contact sheet.")
    }
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func checker(_ rect: CGRect, dark: Bool) {
        let shades: [CGFloat] = dark ? [0.09, 0.22] : [1, 0.82]
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 12) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 12) {
                context.setFillColor(CGColor(gray: shades[(x / 12 + y / 12) % 2], alpha: 1))
                context.fill(CGRect(x: x, y: y, width: min(12, Int(rect.maxX) - x), height: min(12, Int(rect.maxY) - y)))
            }
        }
    }
    func label(_ text: String, x: Int, y: Int) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 13, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
    for c in 0..<3 {
        label(["Original capture", "PNG / light checker", "PNG / dark checker"][c], x: c * column + 12, y: height - 24)
        let scale = min(Double(column - 24) / Double(original.width), Double(overview - 48) / Double(original.height))
        let rect = CGRect(x: Double(c * column + 12), y: Double(height - overview + 12),
                          width: Double(original.width) * scale, height: Double(original.height) * scale)
        checker(rect, dark: c == 2)
        context.interpolationQuality = .high
        context.draw(c == 0 ? original : result, in: rect)
        for (row, corner) in corners.enumerated() {
            let sourceRect = CGRect(x: corner.right ? original.width - crop : 0,
                                    y: corner.bottom ? original.height - crop : 0, width: crop, height: crop)
            let y = height - overview - (row + 1) * rowHeight
            label("\(corner.name), 4x", x: c * column + 12, y: y + rowHeight - 20)
            let target = CGRect(x: c * column + 12, y: y + 4, width: crop * zoom, height: crop * zoom)
            checker(target, dark: c == 2)
            context.interpolationQuality = .none
            context.draw((c == 0 ? original : result).cropping(to: sourceRect)!, in: target)
        }
    }
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".contact-sheet-" + UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try writePNG(context.makeImage()!, to: temporary)
    try FileManager.default.moveItem(at: temporary, to: output)
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    try require(arguments.count >= 2, "Usage: swift prepare-screenshots.swift input output.png [--describe-stats] [--contact-sheet sheet.png] [--mask-from registered-dark.png]")
    let input = URL(fileURLWithPath: arguments.removeFirst()).standardizedFileURL
    let output = URL(fileURLWithPath: arguments.removeFirst()).standardizedFileURL
    var detailed = false
    var sheet: URL?
    var maskURL: URL?
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--describe-stats": detailed = true
        case "--contact-sheet":
            try require(!arguments.isEmpty, "--contact-sheet requires an output PNG path.")
            sheet = URL(fileURLWithPath: arguments.removeFirst()).standardizedFileURL
        case "--mask-from":
            try require(!arguments.isEmpty, "--mask-from requires a prepared PNG reference path.")
            maskURL = URL(fileURLWithPath: arguments.removeFirst()).standardizedFileURL
            try require(maskURL?.pathExtension.lowercased() == "png", "The registered mask must be a PNG.")
        default: throw PreparationError.invalid("Unknown argument.")
        }
    }
    let fm = FileManager.default
    try require(output.pathExtension.lowercased() == "png", "Output extension must be .png.")
    try require(resolvedFileLocation(input) != resolvedFileLocation(output), "Input and output must differ.")
    try require((try? fm.attributesOfItem(atPath: output.path)) == nil, "Refusing to overwrite an existing output or symlink.")
    if let sheet {
        try require(sheet.pathExtension.lowercased() == "png"
                    && resolvedFileLocation(sheet) != resolvedFileLocation(output)
                    && resolvedFileLocation(sheet) != resolvedFileLocation(input),
                    "Contact sheet requires a separate .png output.")
        try require((try? fm.attributesOfItem(atPath: sheet.path)) == nil, "Refusing to overwrite an existing contact sheet or symlink.")
    }
    let bitmap = try Bitmap(url: input)
    let transparentCorners = corners.allSatisfy { bitmap.pixels[$0.index(0, 0, in: bitmap) * 4 + 3] == 0 }
    let prepared: Prepared
    let passthrough = transparentCorners && input.pathExtension.lowercased() == "png"
    try require(!(passthrough && maskURL != nil), "Input PNG already has transparent corners; omit --mask-from to preserve it unchanged.")
    if passthrough {
        prepared = Prepared(pixels: bitmap.pixels, changed: [], records: [], limit: min(90, min(bitmap.width, bitmap.height) / 4))
    } else if let maskURL {
        prepared = try applyRegisteredMask(Bitmap(url: maskURL), to: bitmap)
    } else { prepared = try prepare(bitmap) }
    let result = passthrough ? bitmap.image : try bitmap.makeImage(pixels: prepared.pixels)
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".screenshot-" + UUID().uuidString + ".png")
    defer { try? fm.removeItem(at: temporary) }
    if passthrough { try Data(contentsOf: input).write(to: temporary, options: .withoutOverwriting) }
    else { try writePNG(result, to: temporary) }
    let encoded = try Bitmap(url: temporary)
    try require(encoded.width == bitmap.width && encoded.height == bitmap.height, "PNG changed dimensions.")
    var protected = 0
    for index in 0..<(bitmap.width * bitmap.height) where !prepared.changed.contains(index) {
        let range = (index * 4)..<(index * 4 + 4)
        try require(bitmap.pixels[range] == encoded.pixels[range], "PNG changed a protected decoded pixel at \(index % bitmap.width),\(index / bitmap.width).")
        protected += 1
    }
    if !passthrough {
        try require(encoded.pixels == prepared.pixels, "PNG encoder altered recovered edge samples.")
    }
    try fm.moveItem(at: temporary, to: output)
    if let sheet { try contactSheet(original: bitmap.image, result: result, limit: prepared.limit, output: sheet) }
    let alphas = stride(from: 3, to: encoded.pixels.count, by: 4).map { Int(encoded.pixels[$0]) }
    let stats: [String: Any] = ["input": input.path, "output": output.path,
        "mode": passthrough ? "unchanged-transparent-png" : maskURL != nil ? "registered-reference-alpha" : "white-corner-matte-recovery",
        "maskReference": maskURL?.path as Any? ?? NSNull(),
        "registrationCheck": maskURL == nil ? "not applicable" : "dimensions only; exact frame alignment must be verified by caller",
        "dimensions": [bitmap.width, bitmap.height], "cornerSafetyLimit": prepared.limit,
        "changedPixels": prepared.changed.count, "changedBounds": bounds(of: prepared.changed, width: bitmap.width) as Any? ?? NSNull(),
        "protectedPixels": protected, "protectedRGBABytes": protected * 4, "protectedBytesEqual": true,
        "alpha": ["minimum": alphas.min()!, "maximum": alphas.max()!,
                  "transparentPixels": alphas.filter { $0 == 0 }.count,
                  "partialPixels": alphas.filter { $0 > 0 && $0 < 255 }.count], "corners": prepared.records]
    if detailed {
        let json = try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    } else { print("\(output.path): \(prepared.changed.count) corner pixels changed; \(protected) protected pixels verified unchanged.") }
} catch {
    FileHandle.standardError.write(Data("Screenshot preparation refused: \(error)\n".utf8))
    exit(1)
}
