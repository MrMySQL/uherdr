// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerdrMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Herdr", targets: ["HerdrMac"]), .library(name: "HerdrCore", targets: ["HerdrCore"])],
    dependencies: [.package(path: "Vendor/GhosttyTerminal")],
    targets: [
        .target(name: "HerdrCore"),
        .executableTarget(name: "HerdrMac", dependencies: ["HerdrCore", .product(name: "GhosttyTerminal", package: "GhosttyTerminal")]),
        .executableTarget(name: "HerdrCoreTests", dependencies: ["HerdrCore"], path: "Tests/HerdrCoreTests")
    ]
)
