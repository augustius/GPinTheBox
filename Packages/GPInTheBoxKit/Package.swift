// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "GPInTheBoxKit", platforms: [.iOS("26.0"), .macOS("26.0")], products: [
    .library(name: "Records", targets: ["Records"]),
    .library(name: "Intake", targets: ["Intake"]),
    .library(name: "Assistant", targets: ["Assistant"]),
    .library(name: "ConsultationAudio", targets: ["ConsultationAudio"]),
    .executable(name: "ModelProbe", targets: ["ModelProbe"])
], dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []), .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")], targets: [
    .target(name: "Records"),
    .target(name: "Intake", dependencies: ["Records", .product(name: "Hummingbird", package: "hummingbird")]),
    .target(name: "Assistant", dependencies: ["Records"]),
    .target(name: "ConsultationAudio", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    .executableTarget(name: "ModelProbe", dependencies: ["Assistant", "Records"]),
    .testTarget(name: "RecordsTests", dependencies: ["Records"]),
    .testTarget(name: "IntakeTests", dependencies: ["Intake", .product(name: "HummingbirdTesting", package: "hummingbird")]),
    .testTarget(name: "AssistantTests", dependencies: ["Assistant", "Records"]),
    .testTarget(name: "ConsultationAudioTests", dependencies: ["ConsultationAudio"])
])
