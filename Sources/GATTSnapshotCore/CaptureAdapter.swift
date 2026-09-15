import Foundation

/// How a capture backend is selected.
public enum CaptureTarget: Hashable, Sendable {
    /// Match on the advertised local name (substring, case-insensitive).
    case name(String)
    /// Match on an adapter-specific identifier: a host-scoped UUID on
    /// CoreBluetooth, a device address on BlueZ.
    case identifier(String)
}

public struct CaptureOptions: Hashable, Sendable {
    public var target: CaptureTarget
    /// Required, so the snapshot's profile label is never empty.
    public var profile: String
    /// Opt-in because it reads private API on Apple platforms. See D1.
    public var includeHandles: Bool
    public var scanTimeout: Duration
    /// CoreBluetooth never times out a connection attempt on its own — a
    /// peripheral can match, accept `connect`, and never call back
    /// (platform-notes §4). Every adapter must impose its own bound.
    public var connectTimeout: Duration
    /// How long to wait for Bluetooth to become available. Must be long enough
    /// for a human to answer a first-run TCC dialog, but bounded so CI cannot
    /// hang forever waiting for a prompt nobody will ever see.
    public var authorizationTimeout: Duration
    /// Defaults to the measured policy. Setting `.disabled` turns cache
    /// detection off, which adapters must announce loudly rather than let pass
    /// as a silent success.
    public var cacheDetection: CacheDetectionPolicy

    public init(target: CaptureTarget, profile: String,
                includeHandles: Bool = false,
                scanTimeout: Duration = .seconds(12),
                connectTimeout: Duration = .seconds(15),
                authorizationTimeout: Duration = .seconds(45),
                cacheDetection: CacheDetectionPolicy = .measured) {
        self.target = target
        self.profile = profile
        self.includeHandles = includeHandles
        self.scanTimeout = scanTimeout
        self.connectTimeout = connectTimeout
        self.authorizationTimeout = authorizationTimeout
        self.cacheDetection = cacheDetection
    }
}

public enum CaptureError: Error, CustomStringConvertible, Equatable {
    case bluetoothUnavailable(String)
    case notAuthorized(String)
    case noPeripheralMatched(CaptureTarget, scannedCount: Int)
    case peripheralNotConnectable(name: String)
    case connectTimedOut(name: String, after: Duration)
    case discoveryFailed(String)
    /// Raised when the attribute table came back implausibly fast, which is the
    /// signature of a cached table rather than a real read. Better to refuse
    /// than to emit a snapshot the tool cannot vouch for (platform-notes §3).
    case suspectedCachedTable(durationMs: Double, threshold: Double)

    public var description: String {
        switch self {
        case .bluetoothUnavailable(let s): "Bluetooth unavailable: \(s)"
        case .notAuthorized(let s): "not authorized to use Bluetooth: \(s)"
        case .noPeripheralMatched(let t, let n):
            "no peripheral matched \(t) (saw \(n) advertiser(s))"
        case .peripheralNotConnectable(let name):
            "peripheral '\(name)' advertises as non-connectable"
        case .connectTimedOut(let name, let after):
            "timed out connecting to '\(name)' after \(after)"
        case .discoveryFailed(let s): "attribute discovery failed: \(s)"
        case .suspectedCachedTable(let ms, let threshold):
            "attribute discovery completed in \(ms) ms, below the \(threshold) ms floor — "
            + "this is the signature of a cached service table, not a fresh read. Refusing to "
            + "emit a snapshot that cannot be vouched for."
        }
    }
}

/// The boundary a platform backend implements.
///
/// Everything platform-specific lives behind this: `GATTCapture` (CoreBluetooth)
/// implements it for macOS and iOS, and a BlueZ or Android adapter can be added
/// without touching the model or the diff engine. Adapters own their own
/// capability declaration, which is what keeps cross-adapter diffs honest.
public protocol CaptureAdapter: Sendable {
    /// Registry key, e.g. `"corebluetooth"`.
    static var adapterID: String { get }
    /// Bumped whenever the adapter's declared abilities change.
    static var capabilityVersion: Int { get }

    /// What this adapter recorded for a given set of options — the declared
    /// capabilities intersected with what the run actually enabled.
    static func capabilities(for options: CaptureOptions) -> AdapterCapabilities

    func capture(_ options: CaptureOptions) async throws -> Snapshot

    /// Enumerate advertisers so a user can find the name to pass to `capture`.
    /// Every platform needs this — a BlueZ adapter implements it over the same
    /// discovery it already performs.
    func scan(_ options: ScanOptions) async throws -> [DiscoveredPeripheral]
}

public extension CaptureAdapter {
    /// The adapter's identity block as written into a snapshot.
    static func identity(for options: CaptureOptions) -> AdapterIdentity {
        AdapterIdentity(id: adapterID,
                        capabilityVersion: capabilityVersion,
                        capabilities: capabilities(for: options))
    }
}
