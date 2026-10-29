// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ChargePilot",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CSMC", path: "Sources/CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "ChargePilotCore", dependencies: ["CSMC"], path: "Sources/ChargePilotCore", swiftSettings: v5),
        .executableTarget(name: "ChargePilot", dependencies: ["ChargePilotCore"], path: "Sources/ChargePilot", swiftSettings: v5),
        .executableTarget(name: "ChargePilotHelper", dependencies: ["ChargePilotCore"], path: "Sources/ChargePilotHelper", swiftSettings: v5),
        .executableTarget(name: "ChargePilotCLI", dependencies: ["ChargePilotCore"], path: "Sources/ChargePilotCLI", swiftSettings: v5),
        .testTarget(name: "ChargePilotCoreTests", dependencies: ["ChargePilotCore"], path: "Tests/ChargePilotCoreTests", swiftSettings: v5),
    ]
)
