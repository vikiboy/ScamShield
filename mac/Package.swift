// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScamShield",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ScamShieldAgent", targets: ["ScamShieldAgent"]),
    ],
    targets: [
        .target(
            name: "ScamShieldCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "ScamShieldAgent", dependencies: ["ScamShieldCore"]),
        .testTarget(name: "ScamShieldCoreTests", dependencies: ["ScamShieldCore"]),
    ],
    swiftLanguageModes: [.v5]
)
