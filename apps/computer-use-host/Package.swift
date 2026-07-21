// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComputerUseHost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ComputerUseHost",
            targets: ["ComputerUseHost"]
        ),
        .executable(
            name: "ComputerUseHostTests",
            targets: ["ComputerUseHostTests"]
        ),
        .library(
            name: "ComputerUseHostLib",
            targets: ["ComputerUseHostLib"]
        )
    ],
    targets: [
        .target(
            name: "ComputerUseHostLib",
            dependencies: []
        ),
        .executableTarget(
            name: "ComputerUseHost",
            dependencies: ["ComputerUseHostLib"]
        ),
        .executableTarget(
            name: "ComputerUseHostTests",
            dependencies: ["ComputerUseHostLib"],
            path: "Tests/ComputerUseHostTests"
        )
    ]
)
