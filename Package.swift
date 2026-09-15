// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Limits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Limits", targets: ["Limits"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Limits",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Limits",
            resources: [.process("Resources")],
            linkerSettings: [
                // SwiftPM runs the executable beside Sparkle.framework during
                // development; the packaged app embeds it one level up, in
                // Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
