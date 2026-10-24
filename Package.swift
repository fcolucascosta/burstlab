// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BurstCore",
    products: [.library(name: "BurstCore", targets: ["BurstCore"])],
    targets: [
        .target(name: "BurstCore", path: "Shared"),
        .testTarget(name: "BurstCoreTests", dependencies: ["BurstCore"], path: "Tests", resources: [.copy("Fixtures")])
    ]
)
