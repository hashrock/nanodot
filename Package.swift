// swift-tools-version:5.10
import PackageDescription

// NANODOT_APPSTORE=1 で App Store 用ビルド（APPSTORE を定義し、MCP をコンパイルから外す）
let appStore = Context.environment["NANODOT_APPSTORE"] == "1"
let settings: [SwiftSetting] = appStore ? [.define("APPSTORE")] : []

let package = Package(
    name: "Nanodot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nanodot", targets: ["Nanodot"]),
    ],
    targets: [
        .target(name: "NanodotCore", swiftSettings: settings),
        .executableTarget(
            name: "Nanodot",
            dependencies: ["NanodotCore"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "NanodotCoreTests",
            dependencies: ["NanodotCore"],
            swiftSettings: settings
        ),
    ]
)
