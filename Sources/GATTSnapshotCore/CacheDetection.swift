import Foundation

/// Decides whether an attribute table was actually read off the air or served
/// from a cached copy.
///
/// ## Measured basis
///
/// From the M1 spike (docs/platform-notes.md §3), against an unbonded
/// peripheral on macOS 26.2:
///
/// | measurement                                              | time     |
/// |----------------------------------------------------------|----------|
/// | second `discoverServices` on a live connection (cached)  | `0.0 ms` |
/// | first `discoverServices` after a fresh connect           | `469 ms` |
/// | …round 2                                                  | `439 ms` |
/// | …round 3                                                  | `439 ms` |
/// | …from a brand-new process                                 | `471 ms` |
///
/// A cache hit is not merely fast, it is free — three orders of magnitude of
/// separation. Any threshold in the 5–50 ms band therefore survives variation in
/// table size, host speed and macOS version, so `10 ms` is chosen as a round
/// number near the middle of that band rather than as a tuned value.
///
/// ## Unverified
///
/// **The bonded case is untested.** Persistent GATT caching is only permitted by
/// the spec for *bonded* peripherals, which is precisely where a stale table is
/// most likely — and the numbers above come from an unbonded device
/// (`isLinkEncrypted = 0`, `pairingState = 0`). A bonded peripheral may
/// re-discover on a different timing curve entirely. Do not treat this threshold
/// as validated for bonded devices until that experiment runs; see
/// docs/platform-notes.md §3, "What this does not yet establish".
public struct CacheDetectionPolicy: Hashable, Sendable {
    /// Discovery faster than this is treated as a cached table rather than a
    /// real read. `nil` disables detection entirely.
    public let thresholdMs: Double?

    /// The default policy, based on the measurements above.
    public static let measured = CacheDetectionPolicy(thresholdMs: 10)

    /// Detection off. Callers must surface `disabledWarning` — see `evaluate`.
    public static let disabled = CacheDetectionPolicy(thresholdMs: nil)

    public init(thresholdMs: Double?) {
        self.thresholdMs = thresholdMs
    }

    public var isEnabled: Bool { thresholdMs != nil }

    /// What a caller must tell the user when detection is off.
    ///
    /// An unset safety threshold that quietly becomes a passing check is the
    /// same failure class as reporting a blind spot as a fact: the snapshot
    /// looks vouched-for and is not. Detection must never silently default.
    public static let disabledWarning =
        "cache detection is DISABLED (no threshold set). This snapshot has NOT been checked "
        + "against the possibility that macOS served a cached attribute table instead of "
        + "reading it off the air. Do not treat it as verified."

    public enum Outcome: Hashable, Sendable {
        /// Discovery took long enough to have been a real read.
        case liveRead(durationMs: Double)
        /// Too fast to be anything but a cache hit.
        case suspectedCache(durationMs: Double, thresholdMs: Double)
        /// No threshold configured; nothing was checked.
        case notChecked(durationMs: Double)
    }

    public func evaluate(durationMs: Double) -> Outcome {
        guard let thresholdMs else { return .notChecked(durationMs: durationMs) }
        return durationMs < thresholdMs
            ? .suspectedCache(durationMs: durationMs, thresholdMs: thresholdMs)
            : .liveRead(durationMs: durationMs)
    }
}
