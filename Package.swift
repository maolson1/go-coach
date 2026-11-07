// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoCoach",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GoCoach", targets: ["GoCoach"])
    ],
    targets: [
        .executableTarget(
            name: "GoCoach",
            path: "Sources/GoCoach",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
