// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tursora",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "Tursora",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Tursora",
            linkerSettings: [
                .linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing"),
                // The packaged executable loads Sparkle from Contents/Frameworks.
                // SwiftPM also supplies its own build-directory rpath for smoke runs.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
