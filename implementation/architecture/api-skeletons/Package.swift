// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
    ],
    targets: [
        .target(
            name: "CameraKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
