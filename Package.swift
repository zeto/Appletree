// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Appletree",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppletreeCore", targets: ["AppletreeCore"]),
    ],
    targets: [
        .target(
            name: "AppletreeCore",
            path: "AppletreeCore/Sources/AppletreeCore"
        ),
        .testTarget(
            name: "AppletreeCoreTests",
            dependencies: ["AppletreeCore"],
            path: "AppletreeCore/Tests/AppletreeCoreTests"
        ),
    ]
)
