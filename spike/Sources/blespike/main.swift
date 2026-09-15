import Foundation

func usage() -> Never {
    log("""
    blespike — throwaway M1 hardware spike for gattsnap

    USAGE
      blespike perm [seconds]
      blespike scan [seconds]
      blespike dump  (--name <substring> | --id <uuid>) [--scan-timeout <s>]
      blespike cache (--name <substring> | --id <uuid>) [--rounds <n>] [--scan-timeout <s>]
    """)
    exit(64)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { usage() }
args.removeFirst()

// `--disclaim` re-execs self as its own TCC-responsible process.
if args.contains("--disclaim"), ProcessInfo.processInfo.environment[Disclaim.marker] == nil {
    Disclaim.relaunchSelf()
}

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func matchArg() -> Spike.Match {
    if let n = flag("--name") { return .name(n) }
    if let s = flag("--id"), let u = UUID(uuidString: s) { return .id(u) }
    usage()
}

let scanTimeout = Double(flag("--scan-timeout") ?? "") ?? 12
let rounds = Int(flag("--rounds") ?? "") ?? 3

let command: Spike.Command
switch verb {
case "perm":
    command = .permission(seconds: Double(args.first ?? "") ?? 3)
case "scan":
    command = .scan(seconds: Double(args.first ?? "") ?? 8)
case "dump":
    command = .dump(match: matchArg(), seconds: scanTimeout)
case "cache":
    command = .cache(match: matchArg(), rounds: rounds, seconds: scanTimeout)
case "serve":
    Server(variant: flag("--variant") ?? "a",
           localName: flag("--local-name") ?? "gattsnap-spike").run()
    exit(0)
case "btcycle":
    BTPower.cycle(offSeconds: Double(args.first ?? "") ?? 4)
    exit(0)
default:
    usage()
}

Spike(command: command).run()
