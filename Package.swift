// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChaturbateDVR",
    platforms: [
        .macOS(.v13)
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
            dependencies: []
        ),
    ]
)
