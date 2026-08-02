// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Osler",
    platforms: [.macOS(.v14)],
    products: [
        // Headless flow engine — no UI dependencies, reusable as a standalone package.
        .library(name: "OslerEngine", targets: ["OslerEngine"]),
        // The native SwiftUI app. Open Package.swift in Xcode, pick this scheme, Run.
        .executable(name: "Osler", targets: ["OslerApp"]),
        // CLI test harness: builds sample graphs in code and runs them for real.
        .executable(name: "osler-cli", targets: ["OslerCLI"]),
    ],
    targets: [
        .target(name: "OslerEngine"),
        .executableTarget(name: "OslerApp", dependencies: ["OslerEngine"]),
        .executableTarget(name: "OslerCLI", dependencies: ["OslerEngine"]),
        .testTarget(name: "OslerEngineTests", dependencies: ["OslerEngine"]),
    ]
)
