// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
        // Deliberately separate from ClaudeUsageCore: the root daemon links this and
        // nothing else, so the usage client, networking and keychain code never end
        // up inside a privileged binary.
        .library(name: "SleepLease", targets: ["SleepLease"]),
    ],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "SleepLease"),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SleepLeaseTests", dependencies: ["SleepLease"]),
    ]
)
