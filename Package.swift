// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Thermal",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .executable(name: "thermal", targets: ["ThermalCLI"]),
        .executable(name: "ThermalApp", targets: ["ThermalApp"]),
        .executable(name: "ThermalFanHelper", targets: ["FanHelper"]),
    ],
    targets: [
        // Thin C layer: AppleSMC user-client struct ABI and the private IOHIDEventSystem API.
        // Read-only in M2: no SMC write command is compiled in.
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "SMCKit", dependencies: ["CSMC"]),
        // SMC fan WRITES (allowlisted F{n}md / F{n}Tg). Linked only by the privileged helper.
        .target(
            name: "CFanWrite",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "FanHelperProtocol"),
        .executableTarget(
            name: "FanHelper",
            dependencies: ["CFanWrite", "FanHelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]   // C callbacks + global state; kept simple
        ),
        .executableTarget(name: "ThermalCLI", dependencies: ["SMCKit"]),
        .executableTarget(
            name: "ThermalApp",
            dependencies: ["SMCKit", "FanHelperProtocol"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "SMCKitTests", dependencies: ["SMCKit"]),
    ]
)
