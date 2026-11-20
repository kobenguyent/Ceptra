// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ceptra",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CeptraCore",
            targets: ["CeptraCore"]
        ),
        .executable(
            name: "Ceptra",
            targets: ["Ceptra"]
        )
    ],
    targets: [
        .target(
            name: "CeptraCore",
            path: "Sources/CeptraCore"
        ),
        .executableTarget(
            name: "Ceptra",
            dependencies: ["CeptraCore"],
            path: "Sources/Ceptra"
        ),
        .testTarget(
            name: "CeptraCoreTests",
            dependencies: ["CeptraCore"],
            path: "Tests/CeptraCoreTests"
        )
    ]
)
