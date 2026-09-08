// swift-tools-version: 6.0
import PackageDescription

// Swift wrapper from Lakr233/libghostty-spm 1.5.20260906; see README.md.
let package = Package(
    name: "GhosttyKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"])],
    dependencies: [.package(url: "https://github.com/Lakr233/MSDisplayLink.git", exact: "2.2.0")],
    targets: [
        .target(name: "GhosttyKit", dependencies: ["libghostty"], linkerSettings: [
            .linkedLibrary("c++"), .linkedFramework("Carbon")
        ]),
        .target(name: "GhosttyTerminal", dependencies: ["GhosttyKit", "MSDisplayLink"], resources: [
            .copy("Resources/Ghostty"), .copy("Resources/terminfo")
        ]),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.c4e16970a803/GhosttyKit.xcframework.zip",
            checksum: "bd9bba3b95652900e87a6a0f190f33d82a1d8e42d1c0119c330072be361385da"
        )
    ]
)
