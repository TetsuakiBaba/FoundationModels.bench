import ArgumentParser
import Foundation

/// One-shot runner: every benchmark and probe in sequence, then (optionally) `submit`.
/// This is what `install.sh` runs, so a fresh machine goes from download to shared result unattended.
struct All: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "Run every benchmark and probe (speed, accuracy, tokens, context) in one go, optionally submitting the result."
    )

    @Flag(name: .long, help: "Overwrite existing results for this machine without asking")
    var force = false

    @Flag(name: .long, help: "Run `fmbench submit` when done")
    var submit = false

    @Flag(name: .customLong("skip-context"), help: "Skip `probe context` (the slowest step)")
    var skipContext = false

    @Option(name: .customLong("benchmarks-file"), help: "Results file (shared JSON read by index.html)")
    var file: String = "benchmarks.json"

    func run() async throws {
        enableLineBuffering()
        var common = ["--benchmarks-file", file]
        if force { common.append("--force") }

        var steps: [(name: String, make: () throws -> any AsyncParsableCommand)] = [
            ("bench speed", { try Speed.parse(common) }),
            ("bench accuracy", { try Accuracy.parse(common) }),
            ("probe tokens", { try TokensProbe.parse(common) }),
        ]
        if !skipContext { steps.append(("probe context", { try ContextProbe.parse(common) })) }

        var failed: [(String, String)] = []
        let total = Stopwatch()
        for (i, step) in steps.enumerated() {
            print("\n\(String(repeating: "━", count: 60))\n[\(i + 1)/\(steps.count)] fmbench \(step.name)\n\(String(repeating: "━", count: 60))")
            let sw = Stopwatch()
            do {
                var cmd = try step.make()
                try await cmd.run()
                print("\n✓ \(step.name) done in \(fmtDuration(sw.elapsed))")
            } catch let code as ExitCode where code.rawValue != 0 {
                // requireAvailable() / aborted overwrite: the message was already printed
                failed.append((step.name, "exit \(code.rawValue)"))
                print("\n✗ \(step.name) failed")
                if i == 0 { break }   // if the very first step cannot run, the model is unusable — stop early
            } catch {
                failed.append((step.name, describeError(error).detail))
                print("\n✗ \(step.name) failed: \(describeError(error).detail)")
            }
        }

        print("\n\(String(repeating: "━", count: 60))")
        print("Finished \(steps.count - failed.count)/\(steps.count) steps in \(fmtDuration(total.elapsed))")
        for (name, why) in failed { print("  ✗ \(name): \(why)") }

        if failed.count == steps.count {
            print("Nothing was recorded, so there is nothing to submit.")
            throw ExitCode(1)
        }
        if submit {
            print("")
            let s = try Submit.parse(["--benchmarks-file", file])
            try s.run()
        } else {
            print("Results are in \(file). Share them with:  fmbench submit")
        }
        if !failed.isEmpty { throw ExitCode(1) }
    }
}

private func fmtDuration(_ s: Double) -> String {
    let m = Int(s) / 60, sec = Int(s) % 60
    return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
}
