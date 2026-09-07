// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerdrMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Herdr", targets: ["HerdrMac"]), .library(name: "HerdrCore", targets: ["HerdrCore"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "HerdrCore"),
        .executableTarget(name: "HerdrMac", dependencies: ["HerdrCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "HerdrCoreTests", dependencies: ["HerdrCore"], path: "Tests/HerdrCoreTests")
    ]
)
