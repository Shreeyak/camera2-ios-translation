// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ApiSkeletons",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(
            name: "CameraKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
