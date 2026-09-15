import Foundation

struct ParsedCLIArguments {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var switches: Set<String> = []

    func value(_ option: String) -> String? { values[option] }
    func contains(_ option: String) -> Bool { switches.contains(option) }
}

struct CLIArgumentError: Error, Equatable, CustomStringConvertible {
    let description: String
}

enum CLIArgumentParser {
    static func parse(_ arguments: [String],
                      valueOptions: Set<String>,
                      switches: Set<String>) throws -> ParsedCLIArguments {
        var parsed = ParsedCLIArguments()
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded {
                parsed.positionals.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if valueOptions.contains(argument) {
                guard parsed.values[argument] == nil else {
                    throw CLIArgumentError(description: "option '\(argument)' was provided more than once")
                }
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") else {
                    throw CLIArgumentError(description: "option '\(argument)' requires a value")
                }
                parsed.values[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if switches.contains(argument) {
                guard !parsed.switches.contains(argument) else {
                    throw CLIArgumentError(description: "option '\(argument)' was provided more than once")
                }
                parsed.switches.insert(argument)
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                throw CLIArgumentError(description: "unknown option '\(argument)'")
            }
            parsed.positionals.append(argument)
            index += 1
        }

        return parsed
    }

    static func positiveFiniteDouble(_ raw: String?, option: String,
                                     default defaultValue: Double) throws -> Double {
        guard let raw else { return defaultValue }
        guard let value = Double(raw), value.isFinite, value > 0 else {
            throw CLIArgumentError(
                description: "\(option) requires a positive finite number, got '\(raw)'")
        }
        return value
    }
}
