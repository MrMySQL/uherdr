// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerdrMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Herdr", targets: ["HerdrMac"]), .library(name: "HerdrCore", targets: ["HerdrCore"])],
    dependencies: [.package(path: "Vendor/GhosttyTerminal"),
                   .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.5.0")],
    targets: [
        .target(name: "HerdrCore", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .executableTarget(name: "HerdrMac", dependencies: ["HerdrCore", .product(name: "GhosttyTerminal", package: "GhosttyTerminal")]),
        .executableTarget(name: "HerdrCoreTests", dependencies: ["HerdrCore"], path: "Tests/HerdrCoreTests")
    ]
)
