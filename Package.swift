// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Glut",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Glut", targets: ["Glut"]),
               .executable(name: "GlutHelper", targets: ["GlutHelper"])],
    targets: [
        .target(name: "GlutCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "Glut", dependencies: ["GlutCore"]),
        .executableTarget(name: "GlutHelper", dependencies: ["GlutCore"]),
        .testTarget(name: "GlutCoreTests", dependencies: ["GlutCore"])
    ]
)
