// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyLabManager",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "KeyLabCore",
            resources: [.copy("Resources/kl2-schema.json")]
        ),
        .executableTarget(name: "klctl", dependencies: ["KeyLabCore"]),
        .executableTarget(name: "KeyLabManager", dependencies: ["KeyLabCore"]),
    ]
)
