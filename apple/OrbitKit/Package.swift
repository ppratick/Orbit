// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OrbitKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OrbitKit", targets: ["OrbitKit"])],
    targets: [
        .target(name: "OrbitKit"),
        .testTarget(name: "OrbitKitTests", dependencies: ["OrbitKit"]),
    ]
)
