// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tursora",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tursora",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Tursora",
            linkerSettings: [.linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing")]   // QLPreviewPanel, thumbnails
        )
    ]
)
