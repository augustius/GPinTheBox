// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "KioskProtocol", platforms: [.iOS("26.0"), .macOS("26.0")], products: [
    .library(name: "KioskProtocol", targets: ["KioskProtocol"])
], targets: [
    .target(name: "KioskProtocol"),
    .testTarget(name: "KioskProtocolTests", dependencies: ["KioskProtocol"])
])
