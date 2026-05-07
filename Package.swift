// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ScreenRecorder",
            path: "Sources"
        )
    ]
)
