import Foundation

// TCC attributes a privacy request to the *responsible process* of the process
// tree — for a CLI that is Terminal.app, iTerm, sshd, a CI runner, or whatever
// launched the shell. If that responsible process has no
// NSBluetoothAlwaysUsageDescription, the child is SIGABRT'd by TCC regardless
// of what the child's own Info.plist says.
//
// `responsibility_spawnattrs_setdisclaim` (libSystem SPI, used by launchd and
// Chrome/Firefox updaters) makes a spawned child its own responsible process,
// so TCC evaluates the child's own bundle identity and usage description.

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(
    _ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
) -> Int32

enum Disclaim {
    static let marker = "BLESPIKE_DISCLAIMED"

    /// Re-exec self as a disclaimed child. Returns only on failure.
    static func relaunchSelf() -> Never {
        var exePathBuf = [CChar](repeating: 0, count: 4096)
        var size = UInt32(exePathBuf.count)
        guard _NSGetExecutablePath(&exePathBuf, &size) == 0 else {
            log("!! _NSGetExecutablePath failed"); exit(70)
        }
        let exePath = String(cString: exePathBuf)
        log("disclaim: re-exec \(exePath)")

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        let rc = responsibility_spawnattrs_setdisclaim(&attrs, 1)
        log("disclaim: responsibility_spawnattrs_setdisclaim -> \(rc)")

        // Pass through argv, minus the --disclaim flag that got us here.
        let childArgs = [exePath] + CommandLine.arguments.dropFirst().filter { $0 != "--disclaim" }
        var env = ProcessInfo.processInfo.environment
        env[marker] = "1"
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        var cArgs: [UnsafeMutablePointer<CChar>?] = childArgs.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        cEnv.append(nil)
        defer {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let spawnRC = posix_spawn(&pid, exePath, nil, &attrs, &cArgs, &cEnv)
        guard spawnRC == 0 else {
            log("!! posix_spawn failed: \(spawnRC) \(String(cString: strerror(spawnRC)))")
            exit(70)
        }
        log("disclaim: child pid \(pid); waiting")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        log("disclaim: child exited with \(code)")
        exit(Int32(code))
    }
}
