// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nanodot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nanodot", targets: ["Nanodot"]),
    ],
    targets: [
        .target(name: "NanodotCore"),
        .executableTarget(
            name: "Nanodot",
            dependencies: ["NanodotCore"]
        ),
        .testTarget(
            name: "NanodotCoreTests",
            dependencies: ["NanodotCore"]
        ),
    ]
)
