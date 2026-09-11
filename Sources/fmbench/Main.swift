import ArgumentParser
import Foundation

@main
struct FMBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fmbench",
        abstract: "FoundationModels.bench — benchmark and inspect Apple's on-device Foundation Models (FoundationModels.framework).",
        discussion: """
        Subcommands:
          info            Model / runtime attributes (availability, languages, versions, memory footprint)
          bench speed     Latency & throughput benchmark (TTFT, decode tok/s, prefill, structured output)
          bench accuracy  Built-in task suite scored automatically (or your own JSONL tasks)
          probe context   Empirically find the context-window limit
          probe tokens    Estimate chars-per-token for several text types (tokenizer behaviour)
          run             Run one prompt and print timing stats
          submit          Share your benchmarks.json results as a GitHub Issue (no clone / PR needed)
        """,
        version: fmbenchVersion,
        subcommands: [Info.self, Bench.self, Probe.self, Run.self, Submit.self]
    )
}

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Benchmarks (speed / accuracy).",
        subcommands: [Speed.self, Accuracy.self]
    )
}

struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Empirical probes of model limits and tokenizer behaviour.",
        subcommands: [ContextProbe.self, TokensProbe.self]
    )
}
