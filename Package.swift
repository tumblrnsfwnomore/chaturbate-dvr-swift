// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChaturbateDVR",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "ChaturbateDVR",
            targets: ["ChaturbateDVR"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ChaturbateDVR",
            dependencies: [],
            resources: [
                .copy("WebServer/dashboard.html")
            ]
        ),
        .testTarget(
            name: "ChaturbateDVRTests",
            dependencies: ["ChaturbateDVR"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
