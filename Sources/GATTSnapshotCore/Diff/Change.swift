import Foundation

public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
    case cosmetic
    case additive
    case breaking

    var rank: Int {
        switch self {
        case .cosmetic: 0
        case .additive: 1
        case .breaking: 2
        }
    }

    public static func < (l: Self, r: Self) -> Bool { l.rank < r.rank }
}

/// Where in the table a change happened, in a form that reads back as a path.
public struct AttributePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public var service: BluetoothUUID
    public var serviceInstance: Int
    public var characteristic: BluetoothUUID?
    public var characteristicInstance: Int?
    public var descriptor: BluetoothUUID?
    public var descriptorInstance: Int?

    public init(service: BluetoothUUID, serviceInstance: Int = 0,
                characteristic: BluetoothUUID? = nil, characteristicInstance: Int? = nil,
                descriptor: BluetoothUUID? = nil, descriptorInstance: Int? = nil) {
        self.service = service
        self.serviceInstance = serviceInstance
        self.characteristic = characteristic
        self.characteristicInstance = characteristicInstance
        self.descriptor = descriptor
        self.descriptorInstance = descriptorInstance
    }

    /// Only shows an instance ordinal when it is non-zero, so the common case
    /// stays readable: `180A/2A29` rather than `180A#0/2A29#0`.
    public var description: String {
        var s = "\(service)\(serviceInstance == 0 ? "" : "#\(serviceInstance)")"
        if let c = characteristic {
            s += "/\(c)\((characteristicInstance ?? 0) == 0 ? "" : "#\(characteristicInstance!)")"
        }
        if let d = descriptor {
            s += "/\(d)\((descriptorInstance ?? 0) == 0 ? "" : "#\(descriptorInstance!)")"
        }
        return s
    }

    enum CodingKeys: String, CodingKey {
        case service, characteristic, descriptor
        case serviceInstance = "service_instance"
        case characteristicInstance = "characteristic_instance"
        case descriptorInstance = "descriptor_instance"
    }
}

public enum ChangeKind: String, Codable, Sendable {
    case serviceAdded = "service_added"
    case serviceRemoved = "service_removed"
    case characteristicAdded = "characteristic_added"
    case characteristicRemoved = "characteristic_removed"
    case propertyAdded = "property_added"
    case propertyRemoved = "property_removed"
    case descriptorAdded = "descriptor_added"
    case descriptorRemoved = "descriptor_removed"
    /// Kept distinct from `propertyRemoved` because it breaks a different set of
    /// clients in a different way. See schema-decisions D1.
    case handleShift = "handle_shift"
    case deviceInformationChanged = "device_information_changed"
    case includedServiceAdded = "included_service_added"
    case includedServiceRemoved = "included_service_removed"
    case servicePrimaryChanged = "service_primary_changed"
}

public struct Change: Hashable, Sendable, Codable {
    public var kind: ChangeKind
    public var severity: Severity
    public var path: AttributePath
    public var detail: String
    /// Extra guidance for changes whose consequence is not obvious from the
    /// kind alone — currently handle shifts, which break bonded clients that a
    /// fresh re-discovery test will never catch.
    public var note: String?

    public init(kind: ChangeKind, severity: Severity, path: AttributePath,
                detail: String, note: String? = nil) {
        self.kind = kind
        self.severity = severity
        self.path = path
        self.detail = detail
        self.note = note
    }
}

public enum UnobservableCategory: String, Codable, Sendable {
    /// The comparison actually dropped a finding it would otherwise have
    /// reported — one side saw an attribute the other structurally cannot.
    /// This is what degrades a run.
    case suppressedComparison = "suppressed_comparison"

    /// Neither snapshot could ever have contained this, so nothing was dropped.
    /// The comparison simply does not cover it. Always reported, never
    /// degrading: a CoreBluetooth-to-CoreBluetooth diff can never see GAP/GATT,
    /// so treating that as degradation would mark *every* macOS run degraded
    /// and teach everyone to ignore the signal.
    case standingLimitation = "standing_limitation"
}

/// A range the comparison could not cover, because at least one side's adapter
/// cannot see it.
///
/// This is never folded into `Change` and never dropped. A cross-adapter diff
/// that quietly omits findings and reports "no changes" is the worst failure
/// mode this tool has. See schema-decisions D3.
public struct Unobservable: Hashable, Sendable, Codable {
    public var capability: Capability
    public var category: UnobservableCategory
    /// Adapter ids that could not observe it, so the message can name them.
    public var blindAdapters: [String]
    public var detail: String

    public init(capability: Capability, category: UnobservableCategory,
                blindAdapters: [String], detail: String) {
        self.capability = capability
        self.category = category
        self.blindAdapters = blindAdapters
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case capability, category, detail
        case blindAdapters = "blind_adapters"
    }
}

/// Why `structure_hash` moved while the diff stayed quiet.
///
/// Both real cases have a determined cause; only `undetermined` is genuinely
/// unexplained, and it should be unreachable. Keeping them apart lets M4 render
/// a known cause as guidance and an unknown one as the bug it would be.
public enum QuietHashCause: String, Codable, Sendable {
    /// Schema-1 files can preserve different discovery orders for repeated
    /// UUIDs, even when handles establish the same comparison table.
    case storedOrderDiffers = "stored_order_differs"

    /// Both snapshots carry handles, `--diff-handles` is off. Actionable: the
    /// user opted out of exactly these findings and can opt back in.
    case handlesNotDiffed = "handles_not_diffed"

    /// Findings were dropped from a range the two adapters cannot both observe.
    /// Always accompanied by a `suppressed_comparison` entry and exit 3.
    case adapterCapabilityGap = "adapter_capability_gap"

    /// The two snapshots were captured with different options, so one records
    /// data the other never collected — most commonly one capture used
    /// `--include-handles` and the other did not.
    ///
    /// Kept separate from `adapterCapabilityGap` because the remedy is
    /// different: this one is fixed by re-capturing with matching flags, not by
    /// accepting a platform's limits.
    case captureOptionsDiffer = "capture_options_differ"

    /// Should be unreachable. If this appears, the hash covers something the
    /// diff does not know how to explain — a schema or engine bug.
    case undetermined
}

public struct DiffWarning: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        /// The two snapshots carry different `--profile` labels. A sanity check
        /// on diffing the wrong two files; never affects the verdict.
        case profileMismatch = "profile_mismatch"

        /// `structure_hash` differs but the diff reported nothing at this
        /// level. Without this, CI's cheap hash check and the full diff
        /// contradict each other and the tool undermines its own signal.
        case quietHashDifference = "quiet_hash_difference"

        /// Repeated UUID siblings have no stable identity when handles were not
        /// captured. Findings are still shown, but may reflect reordered
        /// discovery rather than a firmware change.
        case ambiguousIdentity = "ambiguous_identity"
    }

    public var kind: Kind
    public var message: String
    /// Populated for `.quietHashDifference`; more than one cause can apply.
    public var causes: [QuietHashCause]

    public init(kind: Kind, causes: [QuietHashCause] = [], _ message: String) {
        self.kind = kind
        self.causes = causes
        self.message = message
    }
}
