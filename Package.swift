// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Workmate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Workmate", targets: ["Workmate"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [
        .target(name: "WorkmateCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .executableTarget(name: "Workmate", dependencies: ["WorkmateCore"]),
        .testTarget(name: "WorkmateCoreTests", dependencies: ["WorkmateCore"])
    ],
    swiftLanguageModes: [.v5]
)
