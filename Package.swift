// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerdrMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Herdr", targets: ["HerdrMac"]), .library(name: "HerdrCore", targets: ["HerdrCore"])],
    dependencies: [.package(path: "Vendor/GhosttyTerminal"),
                   // cmark-gfm, GitHub's Markdown renderer, for the Markdown preview only.
                   .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0")],
    targets: [
        .target(name: "HerdrCore"),
        // The only code that imports cmark; HerdrCore and the stores stay dependency-free.
        .target(name: "HerdrMarkdown", dependencies: ["HerdrCore",
                                                      .product(name: "cmark-gfm", package: "swift-cmark"),
                                                      .product(name: "cmark-gfm-extensions", package: "swift-cmark")]),
        .executableTarget(name: "HerdrMac", dependencies: ["HerdrCore", "HerdrMarkdown", .product(name: "GhosttyTerminal", package: "GhosttyTerminal")],
                          resources: [.copy("Resources/AgentIcons"), .copy("Resources/FileIcons")]),
        .executableTarget(name: "HerdrCoreTests", dependencies: ["HerdrCore"], path: "Tests/HerdrCoreTests"),
        .executableTarget(name: "HerdrMarkdownTests", dependencies: ["HerdrMarkdown"], path: "Tests/HerdrMarkdownTests")
    ]
)
