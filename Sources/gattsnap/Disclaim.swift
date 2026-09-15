#if os(macOS)
import Foundation

// TCC bills a privacy request to the *responsible process* of the process tree.
// For a CLI that is Terminal.app, iTerm, sshd or a CI runner — not this binary.
// If that process carries no NSBluetoothAlwaysUsageDescription, the child is
// SIGABRT'd with nothing on stderr, whatever this binary's own Info.plist says.
//
// `responsibility_spawnattrs_setdisclaim` makes a spawned child its own
// responsible process, so TCC evaluates gattsnap's own bundle identity. This is
// the fix M1 established empirically; see docs/platform-notes.md §1.

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(
    _ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
) -> Int32

enum Disclaim {
    static let marker = "GATTSNAP_DISCLAIMED"

    static var alreadyDisclaimed: Bool {
        ProcessInfo.processInfo.environment[marker] != nil
    }

    /// True when this binary sits inside a bundle TCC can read an Info.plist
    /// from. Without one, disclaiming only moves the failure.
    static var isInsideAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            || Bundle.main.bundleIdentifier != nil
    }

    /// Re-exec self as a disclaimed child, forwarding stdio and exit code.
    /// Returns only on failure to spawn.
    static func relaunchSelf() -> Never {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        var size = UInt32(pathBuffer.count)
        guard _NSGetExecutablePath(&pathBuffer, &size) == 0 else {
            FileHandle.standardError.write(Data("gattsnap: cannot locate own executable\n".utf8))
            exit(70)
        }
        let executable = String(
            decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        _ = responsibility_spawnattrs_setdisclaim(&attributes, 1)

        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"

        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + CommandLine.arguments.dropFirst()).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, nil, &attributes, &argv, &envp)
        guard result == 0 else {
            let reason = String(validatingCString: strerror(result)) ?? "errno \(result)"
            FileHandle.standardError.write(Data(
                "gattsnap: could not relaunch for Bluetooth permission: \(reason)\n".utf8))
            exit(70)
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // Surface a TCC kill as something actionable rather than as signal 6.
        if (status & 0x7F) == SIGABRT {
            FileHandle.standardError.write(Data("""
                gattsnap: killed by TCC while starting Bluetooth.

                This usually means gattsnap is not inside a signed .app bundle carrying
                NSBluetoothAlwaysUsageDescription. See docs/platform-notes.md §1.

                """.utf8))
            exit(77)
        }
        exit((status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
    }
}
#endif
