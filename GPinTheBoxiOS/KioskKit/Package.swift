// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "KioskKit", platforms: [.iOS("26.0"), .macOS("26.0")], products: [
    .library(name: "KioskKit", targets: ["KioskKit"])
], dependencies: [
    .package(path: "../../Packages/KioskProtocol")
], targets: [
    .target(name: "KioskKit", dependencies: [.product(name: "KioskProtocol", package: "KioskProtocol")]),
    .testTarget(name: "KioskKitTests", dependencies: ["KioskKit", .product(name: "KioskProtocol", package: "KioskProtocol")])
])
