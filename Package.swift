// swift-tools-version: 6.0
import PackageDescription
import Foundation

let echoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/echo-deps").path

let package = Package(
    name: "Whale",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Whale", targets: ["WhaleApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "WhaleAEC", cxxSettings: [
            .define("WEBRTC_MAC"), .define("WEBRTC_POSIX"),
            .unsafeFlags(["-I", echoRoot + "/webrtc-audio-processing-2.1/webrtc", "-I", echoRoot + "/webrtc-audio-processing-2.1/subprojects/abseil-cpp-20240722.0"])
        ], linkerSettings: [.unsafeFlags(["-L", echoRoot, "-lWhaleWebRTC"])]),
        .target(name: "WhaleCore", dependencies: ["WhaleAEC"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "WhaleApp", dependencies: ["WhaleCore", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "WhaleCoreTests", dependencies: ["WhaleCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
