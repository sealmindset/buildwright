// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Buildwright",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Buildwright",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Buildwright"
        ),
        .testTarget(
            name: "BuildwrightTests",
            dependencies: ["Buildwright"],
            path: "Tests/BuildwrightTests"
        )
    ]
)
