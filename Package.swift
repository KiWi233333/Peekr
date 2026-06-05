// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Peekr",
    platforms: [ .macOS(.v14) ],
    dependencies: [
        // SwiftUI hot reload. Compiles to a no-op in release — the only dev-time
        // dependency. See "热更新" in CLAUDE.md for the workflow (Xcode + InjectionIII).
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", from: "1.5.2"),
    ],
    targets: [
        .executableTarget(
            name: "Peekr",
            dependencies: [ .product(name: "Inject", package: "Inject") ],
            path: "Sources/Peekr",
            linkerSettings: [
                // Lets Inject swap code in the running binary. Debug-only so it
                // never reaches release builds.
                .unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(name: "PeekrTests", dependencies: ["Peekr"], path: "Tests/PeekrTests"),
    ]
)
