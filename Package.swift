// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorMediastore",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorMediastore",
            targets: ["CapacitorMediastorePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "CapacitorMediastorePlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/CapacitorMediastorePlugin"),
        .testTarget(
            name: "CapacitorMediastorePluginTests",
            dependencies: ["CapacitorMediastorePlugin"],
            path: "ios/Tests/CapacitorMediastorePluginTests")
    ]
)