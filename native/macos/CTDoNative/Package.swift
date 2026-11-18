// swift-tools-version: 5.9
import Foundation
import PackageDescription

// `CTDOZLITE_LEGACY_MACOS13=1` builds the separate macOS 13 edition. The flag swaps the few
// macOS 14-only SwiftUI calls for fallbacks (see Compat.swift); the default build is unchanged.
let legacy = ProcessInfo.processInfo.environment["CTDOZLITE_LEGACY_MACOS13"] == "1"
let settings: [SwiftSetting] = legacy ? [.define("LEGACY_MACOS13")] : []

let package = Package(
    name: "CTDoNative",
    platforms: [legacy ? .macOS(.v13) : .macOS(.v14)],
    products: [.executable(name: "CTDoNative", targets: ["CTDoNative"])],
    targets: [
        .target(name: "NativeBridge"),
        .executableTarget(name: "CTDoNative", dependencies: ["NativeBridge"], swiftSettings: settings),
        .testTarget(name: "NativeBridgeTests", dependencies: ["NativeBridge"]),
        .testTarget(name: "CTDoNativeTests", dependencies: ["CTDoNative", "NativeBridge"], swiftSettings: settings)
    ]
)
