#if canImport(CoreBluetooth) && os(macOS)
import Foundation
import CoreBluetooth
import GATTHandleProbe

/// The single point where `GATTCapture` touches `GATTHandleProbe`'s availability
/// check. Kept in a file guarded by `os(macOS)` so the import — and therefore
/// the whole private-API module — is absent from an iOS build rather than
/// present and unused.
enum HandleProbeAvailability {
    static var isAvailable: Bool {
        HandleProbe.isAvailable(onServiceClass: CBService.self,
                                characteristicClass: CBCharacteristic.self,
                                descriptorClass: CBDescriptor.self)
    }
}
#endif
