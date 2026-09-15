#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import GATTSnapshotCore

public let gattsnapVersion = "0.1.0"

/// CoreBluetooth-backed capture for macOS and iOS.
///
/// Everything platform-specific stops here: the model, the schema and the diff
/// engine in `GATTSnapshotCore` know nothing about CoreBluetooth, so a BlueZ or
/// Android adapter conforms to the same protocol without touching them.
public struct CoreBluetoothCaptureAdapter: CaptureAdapter {

    public static let adapterID = AdapterRegistry.coreBluetooth
    public static let capabilityVersion = 1

    public init() {}

    /// Declared abilities intersected with what this run enabled.
    ///
    /// Handles are recorded as observed only when `--include-handles` was passed
    /// *and* the platform links the probe. Reporting `handles: true` on a run
    /// that did not record them would make a later diff unable to tell "not
    /// captured" from "unchanged" — the confusion D1 exists to prevent.
    ///
    /// Everything else CoreBluetooth simply cannot see: `CBPeripheral.BDAddress`
    /// returns nil, GAP/GATT are filtered out of discovery, and the raw
    /// advertising PDU is never exposed. See docs/platform-notes.md §2.
    public static func capabilities(for options: CaptureOptions) -> AdapterCapabilities {
        #if os(macOS)
        return AdapterCapabilities(options.includeHandles ? [.handles] : [])
        #else
        // The handle probe is not linked on iOS at all, by design.
        return AdapterCapabilities([])
        #endif
    }

    public func capture(_ options: CaptureOptions) async throws -> Snapshot {
        try await CaptureSession(options: options).run()
    }

    public func scan(_ options: ScanOptions) async throws -> [DiscoveredPeripheral] {
        try await ScanSession(options: options).run()
    }

    /// Whether `--include-handles` can be honoured on this build and OS.
    ///
    /// Returns a reason when it cannot, so the CLI can refuse loudly instead of
    /// quietly writing a snapshot with the flag set and no handles in it.
    public static func handleSupport() -> (available: Bool, reason: String?) {
        #if os(macOS)
        if HandleProbeAvailability.isAvailable {
            return (true, nil)
        }
        return (false, "this macOS no longer exposes attribute handles on CoreBluetooth's "
                     + "model classes; gattsnap will not guess at them")
        #else
        return (false, "attribute handles are only readable on macOS; the probe is not "
                     + "compiled into iOS builds")
        #endif
    }
}
#endif
