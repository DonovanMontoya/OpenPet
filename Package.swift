// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CompanionPet",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "CompanionPet",
            targets: ["CompanionPet"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "CompanionPet",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CompanionPetTests",
            dependencies: ["CompanionPet"]
        ),
    ]
)
