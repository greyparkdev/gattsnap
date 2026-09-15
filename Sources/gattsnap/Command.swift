import Foundation
import GATTSnapshotCore
import GATTSnapshotReport
#if canImport(CoreBluetooth)
import GATTCapture
#endif

@main
struct Gattsnap {

    static let usage = """
    usage: gattsnap <command> [options]

    gattsnap scan [options]
      --seconds <s>           how long to listen, default 8
      --all                   include advertisers that are not connectable
      --format <f>            human (default), json
      --no-color              never colourise (also honours NO_COLOR)

    gattsnap capture (--name <substring> | --id <uuid>) --profile <label> [options]
      --name <substring>      match on the advertised local name (case-insensitive)
      --id <uuid>             match on the peripheral identifier (host-scoped)
      --profile <label>       required product label recorded in the snapshot
      --out <path>            write here instead of stdout
      --include-handles       record attribute handles (macOS only; private API)
      --scan-timeout <s>      default 12
      --connect-timeout <s>   default 15
      --auth-timeout <s>      default 45
      --cache-threshold <ms>  default 10; "off" DISABLES cache detection

    gattsnap diff <base.json> <head.json> [options]
      --format <f>            human (default), json, junit, github, markdown
      --out <path>            write here instead of stdout
      --summary <path>        additionally write a markdown summary here
                              (in CI: --summary "$GITHUB_STEP_SUMMARY")
      --annotate-path <p>     repo-relative path for --format github annotations;
                              defaults to <head.json>
      --base-label <s>        display name for the base side, when the path is a
      --head-label <s>        temporary file rather than something a reader knows
      --diff-handles          compare attribute handles; a shift is breaking
      --fail-on-warning       promote warnings into the exit code
      --no-color              never colourise (also honours NO_COLOR)

    exit codes
      0  no changes
      1  additive or cosmetic changes only
      2  breaking changes present
      3  degraded — findings were dropped from an unobservable range
      4  warnings present, and --fail-on-warning was set
    """

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { print(usage); exit(64) }
        arguments.removeFirst()

        switch command {
        case "scan":
            await scan(arguments)
        case "capture":
            await capture(arguments)
        case "diff":
            diff(arguments)
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        default:
            die("unknown command '\(command)'\n\n\(usage)", code: 64)
        }
    }

    // MARK: - diff

    static func diff(_ arguments: [String]) {
        let parsed = parseArgumentsOrDie(
            arguments,
            valueOptions: ["--format", "--out", "--summary", "--annotate-path",
                           "--base-label", "--head-label"],
            switches: ["--diff-handles", "--fail-on-warning", "--no-color"])
        let paths = parsed.positionals

        guard paths.count == 2 else {
            die("diff needs exactly two snapshot files, got \(paths.count)\n\n\(usage)", code: 64)
        }

        guard let format = OutputFormat.parse(parsed.value("--format") ?? "human") else {
            die("unknown --format '\(parsed.value("--format") ?? "")'; expected one of "
                + OutputFormat.allNames, code: 64)
        }

        let base = load(paths[0])
        let head = load(paths[1])

        let report = DiffEngine.compare(base: base, head: head, options: DiffOptions(
            diffHandles: parsed.contains("--diff-handles"),
            failOnWarning: parsed.contains("--fail-on-warning")))

        let outputPath = parsed.value("--out")
        // Colour only when a human is actually looking at a terminal. Piping to
        // a file or a CI log must never embed escape codes.
        let useColor = format == .human
            && outputPath == nil
            && !parsed.contains("--no-color")
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && isatty(FileHandle.standardOutput.fileDescriptor) == 1

        // Only built for the format that consumes it — reading and skimming the
        // head file a second time is wasted work for every other format.
        let target = format == .github
            ? annotationTarget(headPath: paths[1],
                               override: parsed.value("--annotate-path"),
                               table: head.table)
            : nil

        // A CI runner reads the base out of git into a temp file, and
        // "/tmp/gattsnap-base-MHr6Cr.json" in the verdict line tells a reviewer
        // nothing about which commit they are looking at.
        let baseLabel = parsed.value("--base-label") ?? paths[0]
        let headLabel = parsed.value("--head-label") ?? paths[1]

        do {
            let rendered = try ReportRenderer.render(
                report, format: format,
                baseLabel: baseLabel, headLabel: headLabel, useColor: useColor,
                target: target)
            if let outputPath {
                try rendered.write(toFile: outputPath, atomically: true, encoding: .utf8)
            } else {
                FileHandle.standardOutput.write(Data(rendered.utf8))
            }

            // Independent of --format on purpose. In CI the annotations go to
            // stdout and the summary goes to a file GitHub renders, and needing
            // two invocations to get both would mean diffing twice.
            if let summaryPath = parsed.value("--summary"), !summaryPath.isEmpty {
                let summary = MarkdownReportRenderer.render(
                    report, baseLabel: baseLabel, headLabel: headLabel)
                try appendOrWrite(summary, to: summaryPath)
            }
        } catch {
            die("could not write report: \(error)", code: 70)
        }

        exit(report.exitCode)
    }

    /// Resolves the file GitHub annotations attach to.
    ///
    /// GitHub silently discards an annotation whose path it cannot resolve
    /// against the workspace, so an absolute path — which is what a CI script
    /// naturally produces — yields a run that looks like it found nothing.
    /// Stripping `$GITHUB_WORKSPACE` removes that entire class of confusion
    /// without the user having to know the rule.
    static func annotationTarget(headPath: String,
                                 override: String?,
                                 table: AttributeTable) -> AnnotationTarget? {
        guard let text = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }

        var path = override ?? headPath
        if override == nil,
           let workspace = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"],
           !workspace.isEmpty {
            let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
            if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
        }

        return AnnotationTarget(path: path,
                                lineIndex: SnapshotLineIndex(snapshotText: text),
                                table: table)
    }

    /// `$GITHUB_STEP_SUMMARY` is a shared, append-only file: other steps write to
    /// it too, and truncating it would erase their output.
    static func appendOrWrite(_ text: String, to path: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? handle.close() }
        let existing = try handle.seekToEnd()
        // A heading butted directly against a previous step's last line reads as
        // part of it. One blank line is enough to keep the sections apart.
        let separator = existing > 0 ? "\n" : ""
        try handle.write(contentsOf: Data((separator + text).utf8))
    }

    /// Validation is strict on purpose: a snapshot that cannot be vouched for
    /// must not produce a diff someone might trust.
    static func load(_ path: String) -> Snapshot {
        do {
            return try SnapshotCoding.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch let error as SnapshotCodingError {
            die("refusing \(path): \(error.description)", code: 65)
        } catch {
            die("cannot read \(path): \(error.localizedDescription)", code: 66)
        }
    }

    // MARK: - scan

    static func scan(_ arguments: [String]) async {
        #if !canImport(CoreBluetooth)
        die("scan requires CoreBluetooth; this build has no capture backend", code: 69)
        #else
        let parsed = parseArgumentsOrDie(
            arguments,
            valueOptions: ["--seconds", "--format"],
            switches: ["--all", "--no-color"])
        guard parsed.positionals.isEmpty else {
            die("scan does not accept positional arguments", code: 64)
        }

        // Narrower than the diff formats on purpose: junit, github and markdown
        // all describe a diff report, and silently rendering something else
        // instead would be worse than refusing.
        guard let format = OutputFormat.parse(parsed.value("--format") ?? "human"),
              format == .human || format == .json else {
            die("unknown --format '\(parsed.value("--format") ?? "")'; scan expects human or json",
                code: 64)
        }

        let includeNonConnectable = parsed.contains("--all")
        let seconds = positiveFiniteDouble(parsed.value("--seconds"),
                                           option: "--seconds", default: 8)
        let options = ScanOptions(duration: .seconds(seconds))

        #if os(macOS)
        if !Disclaim.alreadyDisclaimed {
            if !Disclaim.isInsideAppBundle {
                warn("""
                    not running from an .app bundle, so macOS has no Info.plist to read a
                    Bluetooth usage description from. This will very likely be killed by
                    TCC. Build with ./scripts/build-app.sh.
                    """)
            }
            Disclaim.relaunchSelf()
        }
        #endif

        if format == .human {
            FileHandle.standardError.write(Data("gattsnap: listening for \(Int(seconds))s…\n".utf8))
        }

        do {
            let everything = try await CoreBluetoothCaptureAdapter().scan(options)
            // Only connectable devices can be captured, so an unnamed beacon is
            // noise when hunting for a board — but say how many were withheld
            // rather than leave the user wondering where theirs went.
            let found = includeNonConnectable ? everything : everything.filter(\.isCapturable)
            let hidden = everything.count - found.count

            let useColor = format == .human
                && !parsed.contains("--no-color")
                && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
                && isatty(FileHandle.standardOutput.fileDescriptor) == 1

            let rendered = try ScanRenderer.render(found, format: format,
                                                   hiddenCount: hidden, useColor: useColor)
            FileHandle.standardOutput.write(Data(rendered.utf8))
            exit(found.isEmpty ? 1 : 0)
        } catch let error as CaptureError {
            die(error.description, code: 69)
        } catch {
            die("\(error)", code: 70)
        }
        #endif
    }

    // MARK: - capture

    static func capture(_ arguments: [String]) async {
        #if !canImport(CoreBluetooth)
        die("capture requires CoreBluetooth; this build has no capture backend", code: 69)
        #else
        let options = parseCaptureOptions(arguments)

        // Must happen before any CoreBluetooth call — see Disclaim.swift.
        #if os(macOS)
        if !Disclaim.alreadyDisclaimed {
            if !Disclaim.isInsideAppBundle {
                warn("""
                    not running from an .app bundle, so macOS has no Info.plist to read a
                    Bluetooth usage description from. This will very likely be killed by
                    TCC. Build with ./scripts/build-app.sh.
                    """)
            }
            Disclaim.relaunchSelf()
        }
        #endif

        do {
            let snapshot = try await CoreBluetoothCaptureAdapter().capture(options.capture)
            // Validate before writing: a snapshot that fails its own checks must
            // never reach a repo, where it would be trusted.
            try SnapshotCoding.validate(snapshot)
            let encoded = try SnapshotCoding.encode(snapshot)

            if let path = options.outputPath {
                try encoded.write(to: URL(fileURLWithPath: path))
                summarize(snapshot, path: path, options: options)
            } else {
                FileHandle.standardOutput.write(encoded)
            }
        } catch let error as CaptureError {
            die(error.description, code: 69)
        } catch let error as SnapshotCodingError {
            die("refusing to write a snapshot that fails validation: \(error.description)", code: 70)
        } catch {
            die("\(error)", code: 70)
        }
        #endif
    }

    #if canImport(CoreBluetooth)
    struct ParsedOptions {
        var capture: CaptureOptions
        var outputPath: String?
        var cacheDisabled: Bool
        var includeHandles: Bool
    }

    static func parseCaptureOptions(_ arguments: [String]) -> ParsedOptions {
        let parsed = parseArgumentsOrDie(
            arguments,
            valueOptions: ["--name", "--id", "--profile", "--out", "--scan-timeout",
                           "--connect-timeout", "--auth-timeout", "--cache-threshold"],
            switches: ["--include-handles"])
        guard parsed.positionals.isEmpty else {
            die("capture does not accept positional arguments", code: 64)
        }

        guard let profile = parsed.value("--profile"),
              !profile.trimmingCharacters(in: .whitespaces).isEmpty else {
            die("--profile is required: it labels which product this snapshot belongs to", code: 64)
        }

        let name = parsed.value("--name")
        let identifier = parsed.value("--id")
        guard (name == nil) != (identifier == nil) else {
            die("exactly one of --name or --id is required", code: 64)
        }

        let target: CaptureTarget
        if let name {
            guard !name.isEmpty else { die("--name must not be empty", code: 64) }
            target = .name(name)
        } else if let identifier {
            guard !identifier.isEmpty else { die("--id must not be empty", code: 64) }
            target = .identifier(identifier)
        } else {
            fatalError("selector validation above is exhaustive")
        }

        // An unset threshold DISABLES detection and must never silently default
        // to a passing check.
        var cachePolicy = CacheDetectionPolicy.measured
        var cacheDisabled = false
        if let raw = parsed.value("--cache-threshold") {
            if raw.lowercased() == "off" {
                cachePolicy = .disabled
                cacheDisabled = true
            } else if let milliseconds = Double(raw), milliseconds.isFinite, milliseconds > 0 {
                cachePolicy = CacheDetectionPolicy(thresholdMs: milliseconds)
            } else {
                die("--cache-threshold takes milliseconds or \"off\", got \"\(raw)\"", code: 64)
            }
        }

        let includeHandles = parsed.contains("--include-handles")
        if includeHandles {
            let support = CoreBluetoothCaptureAdapter.handleSupport()
            if !support.available {
                die("--include-handles was requested but "
                    + (support.reason ?? "handles are unavailable"), code: 69)
            }
        }

        if cacheDisabled { warn(CacheDetectionPolicy.disabledWarning) }

        return ParsedOptions(
            capture: CaptureOptions(
                target: target,
                profile: profile,
                includeHandles: includeHandles,
                scanTimeout: .seconds(positiveFiniteDouble(parsed.value("--scan-timeout"),
                                                           option: "--scan-timeout", default: 12)),
                connectTimeout: .seconds(positiveFiniteDouble(parsed.value("--connect-timeout"),
                                                              option: "--connect-timeout", default: 15)),
                authorizationTimeout: .seconds(positiveFiniteDouble(parsed.value("--auth-timeout"),
                                                                    option: "--auth-timeout", default: 45)),
                cacheDetection: cachePolicy),
            outputPath: parsed.value("--out"),
            cacheDisabled: cacheDisabled,
            includeHandles: includeHandles)
    }

    static func summarize(_ snapshot: Snapshot, path: String, options: ParsedOptions) {
        let services = snapshot.table.services.count
        let characteristics = snapshot.table.services.reduce(0) { $0 + $1.characteristics.count }
        let duration = snapshot.captureMetadata.discoveryDurationMs.map { "\($0) ms" } ?? "unknown"
        FileHandle.standardError.write(Data("""
            gattsnap: wrote \(path)
              profile          \(snapshot.profile)
              structure_hash   \(snapshot.structureHash)
              attributes       \(services) service(s), \(characteristics) characteristic(s)
              discovery        \(duration)\(options.cacheDisabled ? "  (NOT checked for caching)" : "")
              handles          \(options.includeHandles ? "recorded" : "not recorded")

            """.utf8))
    }
    #endif

    // MARK: - Output

    static func parseArgumentsOrDie(_ arguments: [String],
                                    valueOptions: Set<String>,
                                    switches: Set<String>) -> ParsedCLIArguments {
        do {
            return try CLIArgumentParser.parse(arguments,
                                               valueOptions: valueOptions,
                                               switches: switches)
        } catch let error as CLIArgumentError {
            die(error.description, code: 64)
        } catch {
            die("could not parse arguments: \(error)", code: 64)
        }
    }

    static func positiveFiniteDouble(_ raw: String?, option: String,
                                     default defaultValue: Double) -> Double {
        do {
            return try CLIArgumentParser.positiveFiniteDouble(
                raw, option: option, default: defaultValue)
        } catch let error as CLIArgumentError {
            die(error.description, code: 64)
        } catch {
            die("could not parse \(option): \(error)", code: 64)
        }
    }

    static func die(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("gattsnap: \(message)\n".utf8))
        exit(code)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("gattsnap: WARNING — \(message)\n".utf8))
    }
}
