// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Strays",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Strays", targets: ["Strays"]),
    ],
    targets: [
        // Everything that inspects the machine. No UI, so the CLI and the tests use it too.
        .target(
            name: "StraysCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Strays",
            dependencies: ["StraysCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .testTarget(
            name: "StraysCoreTests",
            dependencies: ["StraysCore"]
        ),
    ]
)
