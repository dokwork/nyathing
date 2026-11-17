// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nyathing",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "nyathing", targets: ["Nyathing"])
    ],
    targets: [
        .executableTarget(name: "Nyathing", resources: [.process("Resources")])
    ]
)
