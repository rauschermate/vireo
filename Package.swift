// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vireo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Vireo", targets: ["Vireo"]),
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownRender", targets: ["MarkdownRender"]),
        .library(name: "MarkdownEditor", targets: ["MarkdownEditor"]),
        .library(name: "VireoCore", targets: ["VireoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
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
            name: "MarkdownRender",
            dependencies: ["MarkdownEngine"]
        ),
        .target(
            name: "MarkdownEditor",
            dependencies: ["MarkdownEngine", "MarkdownRender"]
        ),
        .executableTarget(
            name: "Vireo",
            dependencies: ["MarkdownEngine", "MarkdownRender", "MarkdownEditor", "VireoCore"]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"]
        ),
    ]
)
