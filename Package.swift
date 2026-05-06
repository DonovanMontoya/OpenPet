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
                .copy("Resources/DefaultPets"),
            ]
        ),
        .testTarget(
            name: "CompanionPetTests",
            dependencies: ["CompanionPet"]
        ),
    ]
)
