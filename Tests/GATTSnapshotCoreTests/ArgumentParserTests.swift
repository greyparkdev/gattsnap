import Testing
@testable import gattsnap

@Suite("CLI argument parsing")
struct ArgumentParserTests {
    private let values: Set<String> = ["--format", "--out"]
    private let switches: Set<String> = ["--diff-handles", "--no-color"]

    @Test("Rejects unknown options instead of silently skipping them")
    func unknownOption() {
        #expect(throws: CLIArgumentError(description: "unknown option '--diff-hanldes'")) {
            try CLIArgumentParser.parse(
                ["base.json", "head.json", "--diff-hanldes"],
                valueOptions: values, switches: switches)
        }
    }

    @Test("Rejects missing option values")
    func missingValue() {
        #expect(throws: CLIArgumentError(description: "option '--format' requires a value")) {
            try CLIArgumentParser.parse(
                ["base.json", "head.json", "--format"],
                valueOptions: values, switches: switches)
        }
    }

    @Test("Rejects duplicate options")
    func duplicateOption() {
        #expect(throws: CLIArgumentError(
            description: "option '--diff-handles' was provided more than once")) {
            try CLIArgumentParser.parse(
                ["--diff-handles", "--diff-handles"],
                valueOptions: values, switches: switches)
        }
    }

    @Test("Parses positional files, values and switches explicitly")
    func validArguments() throws {
        let parsed = try CLIArgumentParser.parse(
            ["base.json", "head.json", "--format", "json", "--diff-handles"],
            valueOptions: values, switches: switches)
        #expect(parsed.positionals == ["base.json", "head.json"])
        #expect(parsed.value("--format") == "json")
        #expect(parsed.contains("--diff-handles"))
    }

    @Test("Rejects nonfinite and nonpositive durations")
    func invalidDurations() {
        for raw in ["nan", "inf", "0"] {
            #expect(throws: CLIArgumentError.self) {
                try CLIArgumentParser.positiveFiniteDouble(
                    raw, option: "--seconds", default: 8)
            }
        }
    }
}
