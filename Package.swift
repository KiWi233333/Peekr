// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Peekr",
    platforms: [ .macOS(.v14) ],
    targets: [
        .executableTarget(name: "Peekr", path: "Sources/Peekr"),
        .testTarget(name: "PeekrTests", dependencies: ["Peekr"], path: "Tests/PeekrTests"),
    ]
)
