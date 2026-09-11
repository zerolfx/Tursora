// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tursora",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tursora",
            path: "Sources/Tursora",
            linkerSettings: [.linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing")]   // QLPreviewPanel, thumbnails
        )
    ]
)
