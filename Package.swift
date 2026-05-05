// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DockSwipe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DockSwipe", targets: ["DockSwipe"])
    ],
    targets: [
        .executableTarget(name: "DockSwipe")
    ]
)
