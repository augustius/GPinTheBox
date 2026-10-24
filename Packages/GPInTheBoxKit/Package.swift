// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GPInTheBoxKit", platforms: [.macOS("26.0")], products: [
    .library(name: "Records", targets: ["Records"]),
    .library(name: "Intake", targets: ["Intake"]),
    .library(name: "Assistant", targets: ["Assistant"]),
    .executable(name: "ModelProbe", targets: ["ModelProbe"])
], dependencies: [.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")], targets: [
    .target(name: "Records"),
    .target(name: "Intake", dependencies: ["Records", .product(name: "Hummingbird", package: "hummingbird")]),
    .target(name: "Assistant", dependencies: ["Records"]),
    .executableTarget(name: "ModelProbe", dependencies: ["Assistant", "Records"]),
    .testTarget(name: "RecordsTests", dependencies: ["Records"]),
    .testTarget(name: "IntakeTests", dependencies: ["Intake", .product(name: "HummingbirdTesting", package: "hummingbird")]),
    .testTarget(name: "AssistantTests", dependencies: ["Assistant", "Records"])
])
