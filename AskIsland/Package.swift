// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AskIsland",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AskIsland", targets: ["AskIsland"]),
        .executable(name: "ask-island", targets: ["ask-island"]),
    ],
    targets: [
        .target(name: "AskIslandCore"),
        .executableTarget(name: "AskIsland", dependencies: ["AskIslandCore"]),
        .executableTarget(name: "ask-island", dependencies: ["AskIslandCore"]),
        .testTarget(name: "AskIslandCoreTests", dependencies: ["AskIslandCore"]),
    ],
    swiftLanguageModes: [.v5]
)
