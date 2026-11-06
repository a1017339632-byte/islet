// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "Islet", targets: ["Islet"])
    ],
    targets: [
        .target(
            name: "Islet",
            path: "Sources/Islet"
        )
    ]
)
