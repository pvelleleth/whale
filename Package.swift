// swift-tools-version: 6.0
import PackageDescription
import Foundation

let echoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/echo-deps").path

let package = Package(
    name: "Whale",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Whale", targets: ["WhaleApp"])],
    targets: [
        .target(name: "WhaleAEC", cxxSettings: [
            .define("WEBRTC_MAC"), .define("WEBRTC_POSIX"),
            .unsafeFlags(["-I", echoRoot + "/webrtc-audio-processing-2.1/webrtc", "-I", echoRoot + "/webrtc-audio-processing-2.1/subprojects/abseil-cpp-20240722.0"])
        ], linkerSettings: [.unsafeFlags(["-L", echoRoot, "-lWhaleWebRTC"])]),
        .target(name: "WhaleCore", dependencies: ["WhaleAEC"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "WhaleApp", dependencies: ["WhaleCore"], resources: [.process("Resources")]),
        .testTarget(name: "WhaleCoreTests", dependencies: ["WhaleCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
