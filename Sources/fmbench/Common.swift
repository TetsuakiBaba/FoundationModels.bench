import ArgumentParser
import Foundation
import FoundationModels

// MARK: - Shared CLI options

struct ModelOptions: ParsableArguments {
    @Option(name: .customLong("use-case"), help: "Model use case: general | contentTagging")
    var useCase: String = "general"

    @Flag(name: .long, help: "Use permissiveContentTransformations guardrails instead of the default guardrails")
    var permissive: Bool = false

    @Option(name: .long, help: "Sampling mode: default | greedy | topk:<k> | topp:<p>")
    var sampling: String = "default"

    @Option(name: .long, help: "Sampling temperature")
    var temperature: Double?

    @Option(name: .long, help: "Seed for random sampling (topk / topp)")
    var seed: UInt64?

    @Option(name: .customLong("max-tokens"), help: "maximumResponseTokens")
    var maxTokens: Int?

    @Option(name: .long, help: "Session instructions (system prompt)")
    var instructions: String?

    func makeModel() throws -> SystemLanguageModel {
        let uc: SystemLanguageModel.UseCase
        switch useCase.lowercased() {
        case "general": uc = .general
        case "contenttagging", "content-tagging", "tagging": uc = .contentTagging
        default: throw ValidationError("Unknown use case '\(useCase)' (general | contentTagging)")
        }
        let guardrails: SystemLanguageModel.Guardrails = permissive ? .permissiveContentTransformations : .default
        return SystemLanguageModel(useCase: uc, guardrails: guardrails)
    }

    func samplingMode() throws -> GenerationOptions.SamplingMode? {
        let s = sampling.lowercased()
        if s == "default" { return nil }
        if s == "greedy" { return .greedy }
        if s.hasPrefix("topk:"), let k = Int(s.dropFirst(5)) { return .random(top: k, seed: seed) }
        if s.hasPrefix("topp:"), let p = Double(s.dropFirst(5)) { return .random(probabilityThreshold: p, seed: seed) }
        throw ValidationError("Unknown sampling '\(sampling)' (default | greedy | topk:<k> | topp:<p>)")
    }

    func makeGenerationOptions(maxTokens override: Int? = nil,
                               forceSampling: GenerationOptions.SamplingMode?? = nil) throws -> GenerationOptions {
        let mode: GenerationOptions.SamplingMode?
        if let forced = forceSampling { mode = forced } else { mode = try samplingMode() }
        return GenerationOptions(sampling: mode, temperature: temperature, maximumResponseTokens: override ?? maxTokens)
    }

    func makeSession(instructions override: String? = nil) throws -> LanguageModelSession {
        let model = try makeModel()
        let ins: String? = override ?? instructions
        return LanguageModelSession(model: model, instructions: ins)
    }

    var summary: [String: Any] {
        var d: [String: Any] = ["useCase": useCase, "guardrails": permissive ? "permissiveContentTransformations" : "default",
                                "sampling": sampling]
        if let temperature { d["temperature"] = temperature }
        if let maxTokens { d["maxTokens"] = maxTokens }
        if let seed { d["seed"] = seed }
        if let instructions { d["instructions"] = instructions }
        return d
    }
}

/// Make stdout line-buffered so progress is visible when piped/redirected.
func enableLineBuffering() { setvbuf(stdout, nil, _IOLBF, 0) }

// MARK: - Timing

func seconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

struct Stopwatch {
    let start = ContinuousClock.now
    var elapsed: Double { seconds(start.duration(to: .now)) }
}

// MARK: - Generation helpers

struct GenResult {
    var text: String = ""
    var ttft: Double? = nil          // time to first streamed snapshot
    var total: Double = 0
    var chunks: Int = 0             // number of streamed snapshots
    var errorKind: String? = nil
    var error: String? = nil

    var ok: Bool { error == nil }
    var decodeTime: Double? { ttft.map { max(total - $0, 0) } }
    var chunksPerSecond: Double? {
        guard let d = decodeTime, d > 0, chunks > 1 else { return nil }
        return Double(chunks - 1) / d
    }
    var charsPerSecond: Double? {
        guard let d = decodeTime, d > 0 else { return nil }
        return Double(text.count) / d
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["total_s": total, "chunks": chunks, "chars": text.count, "ok": ok]
        if let ttft { d["ttft_s"] = ttft }
        if let dt = decodeTime { d["decode_s"] = dt }
        if let cps = chunksPerSecond { d["chunks_per_s"] = cps }
        if let c = charsPerSecond { d["chars_per_s"] = c }
        if let errorKind { d["errorKind"] = errorKind }
        if let error { d["error"] = error }
        return d
    }
}

/// Streams a plain-text response and records timing.
func streamGenerate(session: LanguageModelSession, prompt: String, options: GenerationOptions) async -> GenResult {
    var r = GenResult()
    let sw = Stopwatch()
    do {
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            if r.ttft == nil { r.ttft = sw.elapsed }
            r.chunks += 1
            r.text = snapshot.content
        }
    } catch {
        let (k, d) = describeError(error)
        r.errorKind = k
        r.error = d
    }
    r.total = sw.elapsed
    return r
}

/// Non-streaming response (used where only the total time matters).
func generate(session: LanguageModelSession, prompt: String, options: GenerationOptions) async -> GenResult {
    var r = GenResult()
    let sw = Stopwatch()
    do {
        let response = try await session.respond(to: prompt, options: options)
        r.text = response.content
        r.chunks = 1
    } catch {
        let (k, d) = describeError(error)
        r.errorKind = k
        r.error = d
    }
    r.total = sw.elapsed
    return r
}

func describeError(_ error: Error) -> (kind: String, detail: String) {
    if let e = error as? LanguageModelSession.GenerationError {
        let kind: String
        switch e {
        case .exceededContextWindowSize: kind = "exceededContextWindowSize"
        case .assetsUnavailable: kind = "assetsUnavailable"
        case .guardrailViolation: kind = "guardrailViolation"
        case .unsupportedGuide: kind = "unsupportedGuide"
        case .unsupportedLanguageOrLocale: kind = "unsupportedLanguageOrLocale"
        case .decodingFailure: kind = "decodingFailure"
        case .rateLimited: kind = "rateLimited"
        case .concurrentRequests: kind = "concurrentRequests"
        case .refusal: kind = "refusal"
        @unknown default: kind = "unknownGenerationError"
        }
        return (kind, e.errorDescription ?? String(describing: e))
    }
    return (String(describing: type(of: error)), error.localizedDescription)
}

func describeAvailability(_ a: SystemLanguageModel.Availability) -> String {
    switch a {
    case .available: return "available"
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return "unavailable (deviceNotEligible)"
        case .appleIntelligenceNotEnabled: return "unavailable (appleIntelligenceNotEnabled)"
        case .modelNotReady: return "unavailable (modelNotReady)"
        @unknown default: return "unavailable (unknown reason)"
        }
    }
}

func requireAvailable(_ model: SystemLanguageModel) throws {
    guard model.isAvailable else {
        throw ValidationError("Model is \(describeAvailability(model.availability)). Run `fmbench info` for details.")
    }
}

// MARK: - System probing

enum Sys {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        if size == 4 { return Int64(Int32(truncatingIfNeeded: v)) }
        return v
    }

    static func shell(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    struct Proc {
        let pid: Int32
        let rssKB: Int
        let name: String
        var key: String { "\(name)[\(pid)]" }
    }

    static let inferenceProcessPatterns = ["InferenceProvider", "modelmanagerd", "modelcatalogd", "ModelCatalogAgent"]

    /// Processes that belong to the on-device inference stack, with resident memory.
    static func inferenceProcesses() -> [Proc] {
        let out = shell("/bin/ps", ["-axo", "pid=,rss=,comm="])
        var result: [Proc] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let rss = Int(parts[1]) else { continue }
            let path = parts[2...].joined(separator: " ")
            let name = (path as NSString).lastPathComponent
            if inferenceProcessPatterns.contains(where: { name.contains($0) }) {
                result.append(Proc(pid: pid, rssKB: rss, name: name))
            }
        }
        return result.sorted { $0.pid < $1.pid }
    }
}

/// Periodically samples the RSS of inference-stack processes and keeps the peak per process.
final class RSSSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private(set) var peak: [String: Int] = [:]
    private(set) var baseline: [String: Int] = [:]

    func recordBaseline() {
        let procs = Sys.inferenceProcesses()
        lock.lock(); defer { lock.unlock() }
        for p in procs { baseline[p.key] = p.rssKB; peak[p.key] = max(peak[p.key] ?? 0, p.rssKB) }
    }

    func sample() {
        let procs = Sys.inferenceProcesses()
        lock.lock(); defer { lock.unlock() }
        for p in procs { peak[p.key] = max(peak[p.key] ?? 0, p.rssKB) }
    }

    func start(interval: Duration = .milliseconds(250)) {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() async {
        task?.cancel()
        _ = await task?.value
        sample()
    }

    var report: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return peak.keys.sorted().map { key in
            var d: [String: Any] = ["process": key, "peak_rss_mb": Double(peak[key] ?? 0) / 1024]
            if let b = baseline[key] {
                d["baseline_rss_mb"] = Double(b) / 1024
                d["delta_mb"] = Double((peak[key] ?? 0) - b) / 1024
            }
            return d
        }
    }

    var peakTotalMB: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(peak.values.reduce(0, +)) / 1024
    }
}

// MARK: - Text generation helpers

let fillerSentences = [
    "The quick brown fox jumps over the lazy dog near the old river bank.",
    "Rivers carry water from the high mountains down to the wide open sea.",
    "A library is a quiet place full of books, maps, and forgotten ideas.",
    "Bread is baked early in the morning by the baker in the small village.",
    "Children play in the park when the weather is warm and the sky is clear.",
    "The train arrives at the station every twenty minutes during the day.",
    "Gardens need sunlight, water, and patience to grow healthy vegetables.",
    "Many birds fly south in autumn and return again when spring arrives.",
]

func fillerText(chars: Int) -> String {
    var s = ""
    var i = 0
    while s.count < chars {
        s += fillerSentences[i % fillerSentences.count] + " "
        i += 1
    }
    return String(s.prefix(chars))
}

func fillerText(words: Int) -> String {
    var out: [Substring] = []
    var i = 0
    while out.count < words {
        out.append(contentsOf: fillerSentences[i % fillerSentences.count].split(separator: " "))
        i += 1
    }
    return out.prefix(words).joined(separator: " ")
}

// MARK: - Output formatting

func fmtMS(_ s: Double?) -> String {
    guard let s else { return "-" }
    return String(format: "%.0f ms", s * 1000)
}

func fmtNum(_ x: Double?, _ digits: Int = 1) -> String {
    guard let x, x.isFinite else { return "-" }
    return String(format: "%.\(digits)f", x)
}

func printSection(_ title: String) {
    print("\n== \(title) ==")
}

func printKV(_ rows: [(String, String)]) {
    let w = rows.map { $0.0.count }.max() ?? 0
    for (k, v) in rows {
        let lines = v.split(separator: "\n", omittingEmptySubsequences: false)
        print("  " + k.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + (lines.first.map(String.init) ?? ""))
        for extra in lines.dropFirst() {
            print("  " + String(repeating: " ", count: w) + "  " + extra)
        }
    }
}

func printTable(header: [String], rows: [[String]]) {
    let all = [header] + rows
    var widths = Array(repeating: 0, count: header.count)
    for r in all { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
    func line(_ r: [String]) -> String {
        "  " + r.enumerated().map { i, c in c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ")
    }
    print(line(header))
    print("  " + widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
    for r in rows { print(line(r)) }
}

func sanitizeForJSON(_ value: Any) -> Any {
    switch value {
    case let d as Double: return d.isFinite ? d : NSNull()
    case let dict as [String: Any]: return dict.mapValues(sanitizeForJSON)
    case let arr as [Any]: return arr.map(sanitizeForJSON)
    default: return value
    }
}

func printJSON(_ obj: [String: Any]) {
    let clean = sanitizeForJSON(obj)
    if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func oneLine(_ s: String, max: Int = 80) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "⏎").trimmingCharacters(in: .whitespaces)
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}
