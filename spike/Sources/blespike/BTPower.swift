import Foundation

// IOBluetooth carries a long-standing C SPI for controller power. This is the
// only way to toggle Bluetooth from a CLI without sudo or scripting System
// Settings, so it is worth knowing whether a toggle busts the GATT cache.

@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func IOBluetoothPreferenceGetControllerPowerState() -> Int32

enum BTPower {
    static func cycle(offSeconds: Double) {
        log("bt: current power state = \(IOBluetoothPreferenceGetControllerPowerState())")
        log("bt: powering OFF")
        IOBluetoothPreferenceSetControllerPowerState(0)
        Thread.sleep(forTimeInterval: offSeconds)
        log("bt: state while off = \(IOBluetoothPreferenceGetControllerPowerState())")
        log("bt: powering ON")
        IOBluetoothPreferenceSetControllerPowerState(1)
        Thread.sleep(forTimeInterval: 3.0)
        log("bt: state after on = \(IOBluetoothPreferenceGetControllerPowerState())")
    }
}
