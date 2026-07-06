// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "neverfold-lid-extender",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "neverfold-lid-extender",
            path: "Sources/NeverFoldExtender"
        )
    ]
)
