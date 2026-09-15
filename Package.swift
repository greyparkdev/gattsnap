// swift-tools-version: 6.0
import PackageDescription

// GATTSnapshotCore is pure Swift and must keep compiling on Linux: no
// CoreBluetooth, no CryptoKit, no Apple-only Foundation surface. The
// CoreBluetooth-backed GATTCapture target and the gattsnap executable arrive in
// M3/M4 and depend on Core, never the reverse.
//
// The M1 spike is a separate package under spike/ and is not built from here.

let package = Package(
    name: "gattsnap",
    // Apple-platform floor only; Linux is unaffected and Core must keep
    // building there. Duration and modern Foundation need these minimums.
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "GATTSnapshotCore", targets: ["GATTSnapshotCore"]),
        .library(name: "GATTSnapshotReport", targets: ["GATTSnapshotReport"]),
        .executable(name: "gattsnap", targets: ["gattsnap"]),
    ],
    targets: [
        .target(
            name: "GATTSnapshotCore",
            path: "Sources/GATTSnapshotCore"
        ),
        // Private-API handle reads, isolated into their own target so the
        // platform condition below can keep them out of iOS builds entirely.
        // See docs/schema-decisions.md D1.
        .target(
            name: "GATTHandleProbe",
            path: "Sources/GATTHandleProbe"
        ),
        .target(
            name: "GATTCapture",
            dependencies: [
                "GATTSnapshotCore",
                // macOS only. On iOS the module is never linked, so the private
                // selectors are absent from the binary rather than dormant in it.
                .target(name: "GATTHandleProbe", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/GATTCapture"
        ),
        .executableTarget(
            name: "gattsnap",
            dependencies: ["GATTSnapshotCore", "GATTSnapshotReport", "GATTCapture"],
            path: "Sources/gattsnap"
        ),
        // Rendering, kept out of Core so the model and diff engine stay free of
        // presentation, and out of the executable so all three output formats
        // can be unit tested. Builds on Linux like Core.
        .target(
            name: "GATTSnapshotReport",
            dependencies: ["GATTSnapshotCore"],
            path: "Sources/GATTSnapshotReport"
        ),
        .testTarget(
            name: "GATTSnapshotCoreTests",
            dependencies: ["GATTSnapshotCore", "GATTSnapshotReport", "gattsnap"],
            path: "Tests/GATTSnapshotCoreTests",
            // Fixtures are read from the source tree via #filePath rather than a
            // resource bundle, so the fixture-maintenance path can write
            // recomputed hashes back to the real files.
            exclude: ["Fixtures"]
        ),
    ]
)
