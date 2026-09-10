import ArgumentParser
import Foundation
import FoundationModels

@Generable
struct ProductListing {
    @Guide(description: "Short product name")
    var name: String
    @Guide(description: "Price in USD")
    var price: Double
    @Guide(description: "One-sentence marketing description")
    var description: String
    @Guide(description: "Three short tags", .count(3))
    var tags: [String]
}

struct Speed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Latency & throughput benchmark: cold start, TTFT, decode tokens/s, prefill scaling, structured output."
    )

    @OptionGroup var model: ModelOptions

    @Option(name: .long, help: "Repetitions per measurement")
    var runs: Int = 3

    @Option(name: .customLong("decode-tokens"), help: "maximumResponseTokens for the decode benchmark (output is truncated to exactly this many tokens)")
    var decodeTokens: Int = 128

    @Option(name: .customLong("prefill-chars"), parsing: .upToNextOption, help: "Prompt sizes (chars) for the prefill benchmark")
    var prefillChars: [Int] = [500, 2000, 6000]

    @Flag(name: .customLong("no-structured"), help: "Skip the @Generable structured-output benchmark")
    var noStructured = false

    @Flag(name: .long, help: "Print each generated text")
    var verbose = false

    @Flag(name: .long, help: "Emit JSON")
    var json = false

    @OptionGroup var save: SaveOptions

    func run() async throws {
        enableLineBuffering()
        try requireAvailable(try model.makeModel())
        let store = try BenchStore.prepare(kind: "speed", opts: save, quiet: json)
        var report: [String: Any] = ["options": model.summary, "runs": runs]
        let sampler = RSSSampler()
        sampler.recordBaseline()
        sampler.start()
        func log(_ s: String) { if !json { print(s) } }

        // 1. Cold start: brand-new session, no prewarm.
        log("[1/5] cold start …")
        let coldSession = try model.makeSession()
        let cold = await streamGenerate(session: coldSession, prompt: "Say hello in one short sentence.",
                                        options: try model.makeGenerationOptions(maxTokens: 16))
        report["coldStart"] = cold.dict

        // 2. Warm: prewarm(), wait, then request.
        log("[2/5] warm start (prewarm) …")
        let warmSession = try model.makeSession()
        warmSession.prewarm()
        try await Task.sleep(for: .seconds(1.5))
        var warmRuns: [GenResult] = []
        for _ in 0..<runs {
            let s = try model.makeSession()
            s.prewarm()
            try await Task.sleep(for: .milliseconds(800))
            warmRuns.append(await streamGenerate(session: s, prompt: "Say hello in one short sentence.",
                                                 options: try model.makeGenerationOptions(maxTokens: 16)))
        }
        report["warmStart"] = ["runs": warmRuns.map { $0.dict }, "ttft_s_mean": mean(warmRuns.compactMap { $0.ttft })]

        // 3. Decode throughput, differential method: same prompt with maxTokens = base and base + N.
        //    tok/s = N / (T(base+N) - T(base)); prefill and first-chunk latency cancel out.
        let base = 32
        log("[3/5] decode throughput (\(runs)× pairs: \(base) vs \(base + decodeTokens) tokens) …")
        let decodePrompt = "Count from 1 to 2000 in English words (one, two, three, four, ...), separated by commas. Do not stop early and do not add any other text."
        var decodePairs: [(short: GenResult, long: GenResult)] = []
        for i in 0..<runs {
            let s1 = try model.makeSession()
            let short = await streamGenerate(session: s1, prompt: decodePrompt, options: try model.makeGenerationOptions(maxTokens: base))
            let s2 = try model.makeSession()
            let long = await streamGenerate(session: s2, prompt: decodePrompt, options: try model.makeGenerationOptions(maxTokens: base + decodeTokens))
            decodePairs.append((short, long))
            if verbose { log("  run \(i + 1): \(oneLine(long.text, max: 120))") }
        }
        let pairsOK = decodePairs.filter { $0.short.ok && $0.long.ok && $0.long.total > $0.short.total }
        let tokPerSec = pairsOK.map { Double(decodeTokens) / ($0.long.total - $0.short.total) }
        let naiveTokPerSec = decodePairs.filter { $0.long.ok }.compactMap { p in p.long.decodeTime.map { Double(base + decodeTokens) / max($0, 1e-9) } }
        let charsPerToken = pairsOK.map { Double($0.long.text.count - $0.short.text.count) / Double(decodeTokens) }
        report["decode"] = [
            "method": "differential: N / (T(base+N) - T(base))",
            "baseTokens": base, "tokens": decodeTokens,
            "runs": decodePairs.map { ["short": $0.short.dict, "long": $0.long.dict] },
            "tokens_per_s_mean": mean(tokPerSec),
            "tokens_per_s_min": tokPerSec.min() ?? .nan,
            "tokens_per_s_max": tokPerSec.max() ?? .nan,
            "naive_tokens_per_s_mean(total-ttft)": mean(naiveTokPerSec),
            "chars_per_token_mean": mean(charsPerToken),
            "ttft_s_mean": mean(decodePairs.compactMap { $0.long.ttft }),
            "chunks_long_mean": mean(decodePairs.map { Double($0.long.chunks) }),
        ] as [String: Any]

        // 4. Prefill scaling: long prompt, 1-token answer → TTFT ≈ prefill.
        log("[4/5] prefill scaling …")
        var prefill: [[String: Any]] = []
        for chars in prefillChars {
            var rs: [GenResult] = []
            for _ in 0..<runs {
                let s = try model.makeSession()
                let prompt = "Read the following text and then reply with just the word DONE.\n\n" + fillerText(chars: chars)
                rs.append(await streamGenerate(session: s, prompt: prompt, options: try model.makeGenerationOptions(maxTokens: 4)))
            }
            let ok = rs.filter { $0.ok }
            let ttft = mean(ok.compactMap { $0.ttft })
            var d: [String: Any] = ["chars": chars, "ttft_s_mean": ttft, "total_s_mean": mean(ok.map { $0.total }),
                                    "chars_per_s": Double(chars) / max(ttft, 1e-9), "errors": rs.compactMap { $0.errorKind }]
            d["est_tokens_per_s(4 chars/token)"] = Double(chars) / 4.0 / max(ttft, 1e-9)
            prefill.append(d)
        }
        report["prefill"] = prefill

        // 5. Structured output (@Generable) vs plain text.
        if !noStructured {
            log("[5/5] structured output …")
            let prompt = "Invent a fictional kitchen gadget and describe it as a product listing."
            var plain: [GenResult] = []
            var structured: [GenResult] = []
            for _ in 0..<runs {
                let s1 = try model.makeSession()
                plain.append(await generate(session: s1, prompt: prompt + " Answer as JSON with keys name, price, description, tags.",
                                            options: try model.makeGenerationOptions(maxTokens: 200)))
                let s2 = try model.makeSession()
                let sw = Stopwatch()
                var r = GenResult()
                do {
                    let resp = try await s2.respond(to: prompt, generating: ProductListing.self,
                                                    options: try model.makeGenerationOptions(maxTokens: 200))
                    r.text = "\(resp.content.name) | $\(resp.content.price) | \(resp.content.tags.joined(separator: ",")) | \(resp.content.description)"
                    r.chunks = 1
                } catch {
                    let (k, d) = describeError(error); r.errorKind = k; r.error = d
                }
                r.total = sw.elapsed
                structured.append(r)
                if verbose { log("  plain: \(oneLine(plain.last!.text)) \n  struct: \(oneLine(r.text))") }
            }
            report["structured"] = [
                "plainJSON_total_s_mean": mean(plain.filter { $0.ok }.map { $0.total }),
                "generable_total_s_mean": mean(structured.filter { $0.ok }.map { $0.total }),
                "plain": plain.map { $0.dict }, "generable": structured.map { $0.dict },
            ]
        } else {
            log("[5/5] structured output skipped")
        }

        await sampler.stop()
        report["memory"] = sampler.report
        report["memoryPeakTotalMB"] = sampler.peakTotalMB
        try store?.save(result: report, options: model.summary)

        if json { printJSON(report); return }

        printSection("Speed benchmark (\(runs) runs)")
        printKV([
            ("Options", model.summary.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")),
            ("Cold start TTFT / total", "\(fmtMS(cold.ttft)) / \(fmtMS(cold.total))" + (cold.ok ? "" : "  ERROR \(cold.error ?? "")")),
            ("Warm start TTFT (mean)", fmtMS(mean(warmRuns.compactMap { $0.ttft }))),
        ])
        printSection("Decode (differential: \(decodeTokens) extra tokens on top of \(base))")
        printTable(header: ["run", "T(\(base))", "T(\(base + decodeTokens))", "Δ", "tok/s", "TTFT", "chunks", "Δchars", "chars/tok", "status"],
                   rows: decodePairs.enumerated().map { i, p in
                       let ok = p.short.ok && p.long.ok
                       let delta = p.long.total - p.short.total
                       return [String(i + 1), fmtMS(p.short.total), fmtMS(p.long.total), fmtMS(delta),
                               ok && delta > 0 ? fmtNum(Double(decodeTokens) / delta) : "-", fmtMS(p.long.ttft), String(p.long.chunks),
                               String(p.long.text.count - p.short.text.count),
                               ok ? fmtNum(Double(p.long.text.count - p.short.text.count) / Double(decodeTokens), 2) : "-",
                               ok ? "ok" : (p.long.errorKind ?? p.short.errorKind ?? "error")]
                   })
        print("  mean \(fmtNum(mean(tokPerSec))) tok/s (min \(fmtNum(tokPerSec.min())), max \(fmtNum(tokPerSec.max())));  naive (tokens ÷ (total−TTFT)): \(fmtNum(mean(naiveTokPerSec))) tok/s")
        printSection("Prefill (prompt size → TTFT with a 1-word answer)")
        printTable(header: ["chars", "TTFT", "chars/s", "≈tok/s (4 chars/tok)", "errors"],
                   rows: prefill.map { [String($0["chars"] as! Int), fmtMS($0["ttft_s_mean"] as? Double),
                                        fmtNum($0["chars_per_s"] as? Double, 0), fmtNum($0["est_tokens_per_s(4 chars/token)"] as? Double, 0),
                                        ($0["errors"] as! [String]).joined(separator: ",")] })
        if let st = report["structured"] as? [String: Any] {
            printSection("Structured output")
            printKV([
                ("Plain text asking for JSON", fmtMS(st["plainJSON_total_s_mean"] as? Double)),
                ("@Generable (constrained decoding)", fmtMS(st["generable_total_s_mean"] as? Double)),
            ])
        }
        printSection("Inference process memory (RSS)")
        printTable(header: ["process", "baseline MB", "peak MB", "delta MB"],
                   rows: sampler.report.map { ["\($0["process"]!)", fmtNum($0["baseline_rss_mb"] as? Double), fmtNum($0["peak_rss_mb"] as? Double), fmtNum($0["delta_mb"] as? Double)] })
    }
}

func mean(_ xs: [Double]) -> Double {
    xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count)
}
