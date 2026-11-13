// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FirepickKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "FirepickCore", targets: ["FirepickCore"]),
        .library(name: "FirepickProvider", targets: ["FirepickProvider"]),
        .library(name: "FirepickBridge", targets: ["FirepickBridge"]),
        .library(name: "FirepickPlayback", targets: ["FirepickPlayback"]),
        .executable(name: "firepick-source-probe", targets: ["FirepickSourceProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.11.0"),
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .target(
            name: "FirepickCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "FirepickProvider",
            dependencies: [
                "FirepickCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "FirepickBridge",
            dependencies: ["FirepickCore", "FirepickProvider"]
        ),
        .target(
            name: "FirepickPlayback",
            dependencies: [
                "FirepickCore",
                .product(name: "MPVKit-GPL", package: "MPVKit"),
            ]
        ),
        .executableTarget(
            name: "FirepickSourceProbe",
            dependencies: [
                "FirepickCore",
                "FirepickProvider",
                "FirepickBridge",
            ]
        ),
        .testTarget(
            name: "FirepickKitTests",
            dependencies: [
                "FirepickCore",
                "FirepickProvider",
                "FirepickBridge",
                "FirepickPlayback",
            ]
        ),
    ]
)

