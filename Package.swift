// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacProfiler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacProfiler",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
