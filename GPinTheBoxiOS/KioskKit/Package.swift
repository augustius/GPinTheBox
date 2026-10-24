// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "KioskKit", platforms: [.iOS("26.0"), .macOS("26.0")], products: [
    .library(name: "KioskKit", targets: ["KioskKit"])
], targets: [
    .target(name: "KioskKit"),
    .testTarget(name: "KioskKitTests", dependencies: ["KioskKit"])
])
