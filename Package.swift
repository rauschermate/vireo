// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vireo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Only libraries are exposed as products so the Xcode project's `Vireo`
        // app target doesn't clash with a same-named package product. The `Vireo`
        // and `VireoSnapshot` executables still run via `swift run <target>`.
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownRender", targets: ["MarkdownRender"]),
        .library(name: "MarkdownEditor", targets: ["MarkdownEditor"]),
        .library(name: "VireoCore", targets: ["VireoCore"]),
        .library(name: "VireoUpdater", targets: ["VireoUpdater"]),
        .library(name: "VireoUpdaterUI", targets: ["VireoUpdaterUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        // Sparkle drives the auto-updater (see Sources/VireoUpdater). Pinned to a
        // released XCFramework so `swift build` fetches a signed binary artifact.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
    ],
    targets: [
        .target(
            name: "MarkdownEngine",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(
            name: "VireoCore"
        ),
        .target(
            name: "VireoUpdater",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .target(
            name: "VireoUpdaterUI",
            dependencies: ["VireoUpdater"]
        ),
        .target(
            name: "MarkdownRender",
            dependencies: ["MarkdownEngine"]
        ),
        .target(
            name: "MarkdownEditor",
            dependencies: ["MarkdownEngine", "MarkdownRender"]
        ),
        .executableTarget(
            name: "Vireo",
            dependencies: ["MarkdownEngine", "MarkdownRender", "MarkdownEditor", "VireoCore", "VireoUpdater", "VireoUpdaterUI"]
        ),
        .executableTarget(
            name: "VireoSnapshot",
            dependencies: ["MarkdownEngine", "MarkdownRender"]
        ),
        .executableTarget(
            name: "VireoUpdaterSnapshot",
            dependencies: ["VireoUpdater", "VireoUpdaterUI"]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"]
        ),
        .testTarget(
            name: "MarkdownEditorTests",
            dependencies: ["MarkdownEditor"]
        ),
        .testTarget(
            name: "VireoUpdaterTests",
            dependencies: ["VireoUpdater"]
        ),
    ]
)
