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
            name: "ComputerUseHostTestRunner",
            targets: ["ComputerUseHostTestRunner"]
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
            name: "ComputerUseHostTestRunner",
            dependencies: ["ComputerUseHostLib"],
            path: "Tests/ComputerUseHostTestRunner"
        ),
        .testTarget(
            name: "ComputerUseHostTests",
            dependencies: ["ComputerUseHostLib", "ComputerUseHostTestRunner"]
        )
    ]
)
