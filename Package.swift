// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
    ],
    targets: [
        // CLI discovery, usage providers and output parsers (no UI).
        .target(name: "HeadroomCore"),
        // The menu bar app: status item, popover panel and settings window.
        .executableTarget(
            name: "Headroom",
            dependencies: ["HeadroomCore"],
            exclude: ["Resources"]
        ),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
