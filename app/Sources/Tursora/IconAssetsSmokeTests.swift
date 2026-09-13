import AppKit
import ImageIO

/// A legacy ICNS bundle displays its own alpha silhouette. macOS does not
/// provide the rounded mask that would hide an opaque square master image.
enum IconAssetsSmokeTests: SmokeSuite {
    static let checkPrefix = "app icon: "
    static func run() {
        print("== app icon assets ==")
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let masterURL = resources.appendingPathComponent("AppIcon.png")
        guard let masterSource = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
              let master = CGImageSourceCreateImageAtIndex(masterSource, 0, nil),
              let alpha = alphaPlane(of: master) else {
            check("master decodes with readable alpha", false); return
        }
        let width = master.width
        let height = master.height
        check("master is 1024 pixels square", width == 1024 && height == 1024)
        check("master outer border is fully transparent",
              (0..<width).allSatisfy { alpha[$0] == 0 && alpha[(height - 1) * width + $0] == 0 }
              && (0..<height).allSatisfy { alpha[$0 * width] == 0 && alpha[$0 * width + width - 1] == 0 })
        // These generous corner samples reject a rectangular tile while
        // permitting changes to the glass artwork, shadow and exact radius.
        let cornerInset = width / 8
        let roundedCorners = [(cornerInset, cornerInset), (width - 1 - cornerInset, cornerInset),
                              (cornerInset, height - 1 - cornerInset), (width - 1 - cornerInset, height - 1 - cornerInset)]
        check("rounded plate leaves all four corner regions transparent",
              roundedCorners.allSatisfy { alpha[$0.1 * width + $0.0] <= 1 })
        let interior = [(width / 2, height / 2), (width / 2, height / 4),
                        (width / 2, height * 3 / 4), (width / 4, height / 2), (width * 3 / 4, height / 2)]
        check("plate has an opaque center and substantial opaque interior",
              interior.allSatisfy { alpha[$0.1 * width + $0.0] >= 250 })
        var minX = width, minY = height, maxX = -1, maxY = -1
        var partialAlphaCount = 0
        for index in alpha.indices {
            let value = alpha[index]
            if value > 0 && value < 255 { partialAlphaCount += 1 }
            if value >= 250 {
                let x = index % width, y = index / width
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        let margins = [minX, minY, width - 1 - maxX, height - 1 - maxY]
        check("opaque plate is inset while filling the main icon area",
              margins.allSatisfy { (32...192).contains($0) }, "opaque margins=\(margins)")
        check("silhouette includes a soft alpha boundary", partialAlphaCount >= 16,
              "partial alpha pixels=\(partialAlphaCount)")

        let familyURL = resources.appendingPathComponent("AppIcon.icns")
        guard let family = CGImageSourceCreateWithURL(familyURL as CFURL, nil) else {
            check("ICNS family decodes", false); return
        }
        let count = CGImageSourceGetCount(family)
        var sizes = Set<Int>()
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(family, index, nil),
                  let alpha = alphaPlane(of: image) else {
                check("ICNS representation \(index) decodes with readable alpha", false); return
            }
            let width = image.width, height = image.height
            check("ICNS representation \(index) is a decoded square", width == height && width > 0)
            sizes.insert(width)
            let corners = [0, width - 1, (height - 1) * width, height * width - 1]
            check("ICNS \(width)-pixel representation \(index) preserves transparent corners and opaque center",
                  corners.allSatisfy { alpha[$0] == 0 } && alpha[(height / 2) * width + width / 2] >= 240)
        }
        check("ICNS family covers 16 pixels through 1024 pixels",
              Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes), "\(sizes.sorted())")
    }

    /// Normalize decoded bitmap layouts before reading alpha. The source may
    /// be RGB, RGBA, premultiplied, or a legacy ICNS representation; assuming
    /// bitmapData byte offsets would accidentally accept the wrong channel.
    private static func alphaPlane(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                              | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }
}
