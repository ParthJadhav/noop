// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandAnalytics", targets: ["StrandAnalytics"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(name: "StrandAnalytics", dependencies: ["WhoopProtocol", "WhoopStore"]),
        .testTarget(name: "StrandAnalyticsTests", dependencies: ["StrandAnalytics"]),
    ]
)
