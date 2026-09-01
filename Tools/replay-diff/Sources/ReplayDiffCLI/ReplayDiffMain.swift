import Foundation
import ReplayDiffKit

/// `replay-diff` entry point.
///
/// Thin on purpose: everything worth testing lives in `ReplayDiffKit` and is exercised by
/// `swift test --package-path Tools/replay-diff`. This file only turns argv into
/// ``DifferOptions``, prints, and picks an exit code.
@main
enum ReplayDiffMain {
    /// 0 = clean, 1 = unexplained difference, 2 = could not run. `Scripts/upgrade-gate.sh`
    /// distinguishes all three.
    enum ExitCode: Int32 {
        case clean = 0
        case differencesFound = 1
        case usage = 2
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let outcome: CommandLineOptions.ParseOutcome
        do {
            outcome = try CommandLineOptions.parse(arguments)
        } catch {
            printErr("replay-diff: \(error)")
            printErr("")
            printErr(CommandLineOptions.helpText)
            exit(ExitCode.usage.rawValue)
        }

        switch outcome {
        case .printHelp:
            print(CommandLineOptions.helpText)
            exit(ExitCode.clean.rawValue)
        case .printLegend:
            print(CommandLineOptions.legendText)
            exit(ExitCode.clean.rawValue)
        case .run(let options):
            run(options)
        }
    }

    private static func run(_ options: CommandLineOptions) -> Never {
        let differ = SemanticDiffer(options: options.differOptions)
        let reportSet: DiffReportSet
        do {
            reportSet = try CaptureSet.compare(
                baselinePath: options.baselinePath,
                candidatePath: options.candidatePath,
                differ: differ
            )
        } catch {
            printErr("replay-diff: \(error)")
            exit(ExitCode.usage.rawValue)
        }

        switch options.format {
        case .text:
            print(reportSet.textReport(), terminator: "")
        case .json:
            do {
                print(try reportSet.jsonReport(), terminator: "")
            } catch {
                printErr("replay-diff: could not encode JSON report: \(error)")
                exit(ExitCode.usage.rawValue)
            }
        }

        let failing = reportSet.hasRegressions
            || (options.failOnExpected && reportSet.totalExpected > 0)
        exit(failing ? ExitCode.differencesFound.rawValue : ExitCode.clean.rawValue)
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
