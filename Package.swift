// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whale",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Whale", targets: ["WhaleApp"])],
    targets: [
        .target(name: "WhaleCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "WhaleApp", dependencies: ["WhaleCore"], resources: [.process("Resources")]),
        .testTarget(name: "WhaleCoreTests", dependencies: ["WhaleCore"])
    ],
    swiftLanguageModes: [.v5]
)
