// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Workmate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Workmate", targets: ["Workmate"])],
    targets: [
        .target(name: "WorkmateCore"),
        .executableTarget(name: "Workmate", dependencies: ["WorkmateCore"]),
        .testTarget(name: "WorkmateCoreTests", dependencies: ["WorkmateCore"])
    ],
    swiftLanguageModes: [.v5]
)
