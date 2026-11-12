// swift-tools-version:5.10
import PackageDescription

// NANODOT_APPSTORE=1 で App Store 用ビルド（APPSTORE を定義し、MCP をコンパイルから外す）。
// iPad 版（iOS）は App Store だけで配るので、どちらの構成でも APPSTORE を定義する（MCP を入れない）
let appStore = Context.environment["NANODOT_APPSTORE"] == "1"
let settings: [SwiftSetting] = appStore ? [.define("APPSTORE")] : [.define("APPSTORE", .when(platforms: [.iOS]))]

let package = Package(
    name: "Nanodot",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Nanodot", targets: ["Nanodot"]),
        // iPad 版（iPad/project.yml）が使う。AppKit に依存しない
        .library(name: "NanodotCore", targets: ["NanodotCore"]),
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
