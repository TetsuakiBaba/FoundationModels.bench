import ArgumentParser
import Foundation
import FoundationModels

// MARK: - Context window probe

struct ContextProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Binary-search the largest prompt that does not raise exceededContextWindowSize."
    )

    @OptionGroup var model: ModelOptions

    @Option(name: .long, help: "Lower bound (words) expected to succeed") var lo: Int = 200
    @Option(name: .long, help: "Upper bound (words) expected to fail") var hi: Int = 16000
    @Option(name: .long, help: "Stop when the bracket is this narrow (words)") var tolerance: Int = 16
    @Flag(name: .customLong("no-calibrate"), help: "Skip measuring chars/token for the filler text") var noCalibrate = false
    @Flag(name: .long) var json = false
    @OptionGroup var save: SaveOptions

    static let preamble = "Read the following text and then reply with just the word DONE.\n\n"

    func run() async throws {
        enableLineBuffering()
        try requireAvailable(try model.makeModel())
        let store = try BenchStore.prepare(kind: "context", opts: save, quiet: json)
        func log(_ s: String) { if !json { print(s) } }

        // Calibrate: tokens → chars ratio for the filler, by forcing a 96-token truncated repetition.
        var charsPerToken: Double? = nil
        if !noCalibrate {
            log("calibrating chars/token for filler text …")
            let s = try model.makeSession()
            let n = 96
            let r = await streamGenerate(session: s, prompt: "Repeat the following text exactly, with no other words:\n\n" + fillerText(words: 400),
                                         options: try model.makeGenerationOptions(maxTokens: n, forceSampling: .some(.greedy)))
            if r.ok, r.text.count > 20 {
                charsPerToken = Double(r.text.count) / Double(n)
                log(String(format: "  ≈ %.2f chars/token (%d chars in %d tokens, %d chunks)", charsPerToken!, r.text.count, n, r.chunks))
            } else {
                log("  calibration failed: \(r.error ?? "empty output")")
            }
        }

        var lo = lo, hi = hi
        var attempts: [[String: Any]] = []
        let options = try model.makeGenerationOptions(maxTokens: 2, forceSampling: .some(.greedy))

        func attempt(_ words: Int) async throws -> (ok: Bool, kind: String?, secs: Double) {
            let s = try model.makeSession()
            let prompt = Self.preamble + fillerText(words: words)
            let r = await streamGenerate(session: s, prompt: prompt, options: options)
            let ok = r.ok
            var d: [String: Any] = ["words": words, "chars": prompt.count, "ok": ok, "seconds": r.total]
            if let k = r.errorKind { d["errorKind"] = k }
            attempts.append(d)
            let label = ok ? "ok" : (r.errorKind ?? "error")
            log(String(format: "  %6d words (%7d chars) → %-26@ %6.0f ms", words, prompt.count, label as NSString, r.total * 1000))
            return (ok, r.errorKind, r.total)
        }

        log("probing bounds …")
        let loRes = try await attempt(lo)
        guard loRes.ok else { throw ValidationError("Lower bound \(lo) words already fails (\(loRes.kind ?? "?")). Lower --lo.") }
        let hiRes = try await attempt(hi)
        guard !hiRes.ok else { throw ValidationError("Upper bound \(hi) words still succeeds. Raise --hi.") }

        log("binary search …")
        var lastFailKind = hiRes.kind
        while hi - lo > tolerance {
            let mid = (lo + hi) / 2
            let r = try await attempt(mid)
            if r.ok { lo = mid } else { hi = mid; lastFailKind = r.kind }
        }

        let okChars = (Self.preamble + fillerText(words: lo)).count
        let failChars = (Self.preamble + fillerText(words: hi)).count
        var report: [String: Any] = ["maxOkWords": lo, "minFailWords": hi, "maxOkChars": okChars, "minFailChars": failChars,
                                     "failureKind": lastFailKind ?? "?", "attempts": attempts, "options": model.summary]
        if let cpt = charsPerToken {
            report["charsPerToken"] = cpt
            report["estimatedContextTokens"] = Double(okChars) / cpt
        }
        try store?.save(result: report, options: model.summary)
        if json { printJSON(report); return }

        printSection("Context window estimate")
        var rows: [(String, String)] = [
            ("Largest OK prompt", "\(lo) words / \(okChars) chars"),
            ("Smallest failing prompt", "\(hi) words / \(failChars) chars (\(lastFailKind ?? "?"))"),
        ]
        if let cpt = charsPerToken {
            rows.append(("Filler chars/token", fmtNum(cpt, 2)))
            rows.append(("≈ Prompt tokens at limit", fmtNum(Double(okChars) / cpt, 0) + "  (+ a few tokens of chat template/instructions overhead)"))
        }
        rows.append(("Attempts", "\(attempts.count)"))
        printKV(rows)
        print("\n  Note: the limit covers instructions + prompt + response together. Public docs state 4,096 tokens.")
    }
}

// MARK: - Tokenizer behaviour probe

struct TokensProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tokens",
        abstract: "Estimate chars/token per text type by forcing truncation at maximumResponseTokens while the model repeats text."
    )

    @OptionGroup var model: ModelOptions
    @Option(name: .long, help: "Token budget per sample") var tokens: Int = 96
    @Flag(name: .long, help: "Print the truncated outputs") var verbose = false
    @Flag(name: .long) var json = false
    @OptionGroup var save: SaveOptions

    static let samples: [(String, String)] = [
        ("english", fillerText(chars: 2500)),
        ("japanese", String(repeating: "昨日は朋友と一緒に京都の古い寺院を訪れ、静かな庭園を眺めながら抹茶を味わいました。秋の紅葉がとても美しく、多くの観光客が写真を撮っていました。夕方には鴨川沿いを散歩し、川面に映る夕日を楽しみました。", count: 8)),
        ("code", String(repeating: "def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)\n\nfor i in range(10):\n    print(i, fib(i))\n\nclass Node:\n    def __init__(self, value, next=None):\n        self.value = value\n        self.next = next\n\n", count: 8)),
        ("numbers", (0..<300).map { String(format: "%d.%03d", ($0 * 7919) % 1000, ($0 * 104729) % 1000) }.joined(separator: " ")),
        ("uuid-hex", (0..<60).map { _ in UUID().uuidString.lowercased() }.joined(separator: " ")),
    ]

    func run() async throws {
        enableLineBuffering()
        try requireAvailable(try model.makeModel())
        let store = try BenchStore.prepare(kind: "tokens", opts: save, quiet: json)
        var rows: [[String: Any]] = []
        for (name, text) in Self.samples {
            let s = try model.makeSession()
            let prompt = "Repeat the following text exactly as written, with no other words, no quotes and no commentary:\n\n" + text
            let r = await streamGenerate(session: s, prompt: prompt,
                                         options: try model.makeGenerationOptions(maxTokens: tokens, forceSampling: .some(.greedy)))
            let truncated = r.ok && r.text.count < text.count - 10
            let chars = r.text.count
            let bytes = r.text.utf8.count
            var d: [String: Any] = ["sample": name, "sourceChars": text.count, "outputChars": chars, "outputBytes": bytes, "chunks": r.chunks,
                                    "tokens": tokens, "truncated": truncated, "ok": r.ok, "decode_s": r.decodeTime ?? -1]
            d["ttft_s"] = r.ttft ?? -1
            d["total_s"] = r.total
            if r.ok {
                d["estPromptTokens"] = Double(prompt.count) / (Double(chars) / Double(tokens))
                d["charsPerToken"] = Double(chars) / Double(tokens)
                d["bytesPerToken"] = Double(bytes) / Double(tokens)
                d["tokensPerSecond"] = Double(tokens) / max(r.decodeTime ?? 1, 1e-9)
            }
            if let e = r.error { d["error"] = e }
            rows.append(d)
            if verbose && !json { print("[\(name)] \(oneLine(r.text, max: 300))\n") }
        }
        let report: [String: Any] = ["tokens": tokens, "samples": rows, "options": model.summary]
        try store?.save(result: report, options: model.summary)
        if json { printJSON(report); return }

        printSection("Tokenizer probe (\(tokens) output tokens forced per sample)")
        printTable(header: ["sample", "chars/tok", "bytes/tok", "≈prompt tok", "TTFT", "total", "chunks", "truncated", "status"],
                   rows: rows.map { d in
                       [d["sample"] as! String, fmtNum(d["charsPerToken"] as? Double, 2), fmtNum(d["bytesPerToken"] as? Double, 2),
                        fmtNum(d["estPromptTokens"] as? Double, 0), fmtMS(d["ttft_s"] as? Double), fmtMS(d["total_s"] as? Double),
                        "\(d["chunks"]!)", "\(d["truncated"]!)",
                        (d["ok"] as! Bool) ? "ok" : oneLine(d["error"] as? String ?? "error", max: 30)]
                   })
        print("\n  chars/tok is only meaningful when truncated=true (the model was cut off by maximumResponseTokens).")
        print("  ≈prompt tok = prompt chars ÷ measured chars/tok for that text type (explains TTFT differences).")
        print("  chunks = number of streamed snapshots; a constant small count means the framework batches streaming output.")
    }
}
