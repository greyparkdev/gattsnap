// swift-tools-version: 6.0
import PackageDescription

// M1 spike package. Started as throwaway; `serve` is now kept deliberately as
// the M2 fixture generator and the future integration-test peripheral, so this
// package outlives the spike even though the probe commands do not.
//
// Deliberately dependency-free and in Swift 5 language mode so the
// CoreBluetooth delegate code does not fight strict concurrency.

let package = Package(
    name: "blespike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "blespike",
            path: "Sources/blespike",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                // The whole point of probe #3: embed an Info.plist directly in
                // the __TEXT,__info_plist section of the Mach-O so a bare CLI
                // binary can carry NSBluetoothAlwaysUsageDescription.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/blespike/Info.plist",
                ])
            ]
        )
    ]
)
