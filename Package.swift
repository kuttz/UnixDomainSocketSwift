// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnixDomainSocket",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "UnixDomainSocket",
            targets: ["UnixDomainSocket"]
        )
    ],
    targets: [
        .target(
            name: "UnixDomainSocket",
            path: "Sources/UnixDomainSocket"
        ),
        .testTarget(
            name: "UnixDomainSocketTests",
            dependencies: ["UnixDomainSocket"],
            path: "Tests/UnixDomainSocketTests"
        )
    ]
)
