// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockZoom",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DockZoom",
            path: "Sources/DockZoom"
        ),
        .testTarget(
            name: "DockZoomTests",
            dependencies: ["DockZoom"],
            path: "Tests/DockZoomTests"
        )
    ]
)
