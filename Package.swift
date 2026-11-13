// swift-tools-version: 6.0
// SPM build used when full Xcode is unavailable (swift build -c release).
// The official build path remains xcodegen + xcodebuild (see Makefile).
import PackageDescription

let package = Package(
    name: "MWBClient",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MWBClient",
            path: "MWBClient",
            exclude: [
                "App/Info.plist",
                "App/MWBClient.entitlements",
                "Resources/Assets.xcassets",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MWBClientTests",
            dependencies: ["MWBClient"],
            path: "MWBClientTests",
            exclude: [
                "**/.DS_Store",
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        )
    ]
)
