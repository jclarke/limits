// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Limits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Limits", targets: ["Limits"])
    ],
    targets: [
        .executableTarget(
            name: "Limits",
            path: "Sources/Limits"
        )
    ]
)
