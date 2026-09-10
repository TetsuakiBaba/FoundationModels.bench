import ArgumentParser
import Foundation
import FoundationModels

// MARK: - Checkers

indirect enum Check {
    case contains([String])          // any of the strings (case-insensitive)
    case containsAll([String])
    case regex(String)
    case exact(String)               // normalized equality
    case number(Double, tolerance: Double)
    case wordCountMax(Int)
    case jsonKeys([String])
    case all([Check])

    func score(_ out: String) -> Double {
        switch self {
        case .contains(let vs):
            return vs.contains { out.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ? 1 : 0
        case .containsAll(let vs):
            return vs.allSatisfy { out.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ? 1 : 0
        case .regex(let p):
            return out.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil ? 1 : 0
        case .exact(let e):
            return Check.normalize(out) == Check.normalize(e) ? 1 : 0
        case .number(let v, let tol):
            guard let n = Check.firstNumber(out) else { return 0 }
            return abs(n - v) <= tol ? 1 : 0
        case .wordCountMax(let n):
            return out.split(whereSeparator: { $0.isWhitespace }).count <= n ? 1 : 0
        case .jsonKeys(let keys):
            guard let s = out.firstIndex(of: "{"), let e = out.lastIndex(of: "}") else { return 0 }
            let slice = String(out[s...e])
            guard let data = slice.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
            return keys.allSatisfy { obj[$0] != nil } ? 1 : 0
        case .all(let cs):
            return cs.allSatisfy { $0.score(out) >= 1 } ? 1 : 0
        }
    }

    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'“”‘’*"))
        while t.hasSuffix(".") || t.hasSuffix("。") || t.hasSuffix("!") { t.removeLast() }
        return t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last number in the text: "1234 + 5678 = 6912" → 6912. (Models often restate the question first.)
    static func firstNumber(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
        guard let re = try? NSRegularExpression(pattern: #"-?\d+(\.\d+)?"#) else { return nil }
        let ns = cleaned as NSString
        let matches = re.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        return Double(ns.substring(with: last.range))
    }

    var describe: String {
        switch self {
        case .contains(let v): return "contains any of \(v)"
        case .containsAll(let v): return "contains all of \(v)"
        case .regex(let p): return "matches /\(p)/"
        case .exact(let e): return "exactly '\(e)'"
        case .number(let v, let t): return "last number = \(v) ±\(t)"
        case .wordCountMax(let n): return "≤ \(n) words"
        case .jsonKeys(let k): return "JSON with keys \(k)"
        case .all(let cs): return cs.map { $0.describe }.joined(separator: " AND ")
        }
    }
}

// MARK: - Tasks

enum StructuredKind { case none, person, sentiment }

struct BenchTask {
    let id: String
    let category: String
    let prompt: String
    var instructions: String? = nil
    let check: Check
    var structured: StructuredKind = .none
}

@Generable
struct PersonInfo {
    @Guide(description: "The person's full name")
    var name: String
    @Guide(description: "Age in years")
    var age: Int
    @Guide(description: "City where the person lives")
    var city: String
}

@Generable
enum SentimentLabel {
    case positive
    case negative
    case neutral
}

let builtinTasks: [BenchTask] = [
    // math
    BenchTask(id: "math-mul", category: "math", prompt: "What is 17 × 23? Answer with just the number.", check: .number(391, tolerance: 0)),
    BenchTask(id: "math-add", category: "math", prompt: "What is 1234 + 5678? Answer with just the number.", check: .number(6912, tolerance: 0)),
    BenchTask(id: "math-percent", category: "math", prompt: "A shirt costs $40 and is 25% off. What is the final price in dollars? Answer with just the number.", check: .number(30, tolerance: 0.01)),
    BenchTask(id: "math-sqrt", category: "math", prompt: "What is the square root of 144? Answer with just the number.", check: .number(12, tolerance: 0)),
    BenchTask(id: "math-speed", category: "math", prompt: "A train travels at 60 km/h for 2.5 hours. How many kilometres does it travel? Answer with just the number.", check: .number(150, tolerance: 0.01)),
    // knowledge
    BenchTask(id: "know-capital", category: "knowledge", prompt: "What is the capital city of Australia? Answer with the city name only.", check: .contains(["Canberra"])),
    BenchTask(id: "know-author", category: "knowledge", prompt: "Who wrote the novel 'Pride and Prejudice'? Answer with the name only.", check: .contains(["Austen"])),
    BenchTask(id: "know-chem", category: "knowledge", prompt: "What is the chemical symbol for gold? Answer with the symbol only.", check: .exact("Au")),
    BenchTask(id: "know-planets", category: "knowledge", prompt: "How many planets are in our solar system? Answer with just the number.", check: .number(8, tolerance: 0)),
    BenchTask(id: "know-ja-mountain", category: "knowledge", prompt: "日本で一番高い山は何ですか？山の名前だけを答えてください。", check: .contains(["富士", "Fuji"])),
    // reasoning
    BenchTask(id: "reason-order", category: "reasoning", prompt: "Tom is taller than Ann. Ann is taller than Bob. Who is the shortest? Answer with the name only.", check: .contains(["Bob"])),
    BenchTask(id: "reason-syllogism", category: "reasoning", prompt: "All bloops are razzies. All razzies are lazzies. Are all bloops definitely lazzies? Answer yes or no.", check: .regex(#"^\W*yes"#)),
    BenchTask(id: "reason-apples", category: "reasoning", prompt: "I have 3 apples. I eat one, then buy 4 more. How many apples do I have now? Answer with just the number.", check: .number(6, tolerance: 0)),
    BenchTask(id: "reason-weekday", category: "reasoning", prompt: "What day of the week comes two days after Monday? Answer with one word.", check: .contains(["Wednesday"])),
    // instruction following
    BenchTask(id: "inst-ok", category: "instruction", prompt: "Reply with exactly the word OK and nothing else.", check: .exact("OK")),
    BenchTask(id: "inst-fruits", category: "instruction", prompt: "List three fruits as a comma-separated list in lowercase letters, with no other text.", check: .regex(#"^\s*[a-z]+,\s?[a-z]+,\s?(and )?[a-z]+\.?\s*$"#)),
    BenchTask(id: "inst-upper", category: "instruction", prompt: "Write the word 'hello' in all uppercase letters. Output only that word.", check: .exact("HELLO")),
    BenchTask(id: "inst-json", category: "instruction", prompt: "Where is the Eiffel Tower? Answer only with a JSON object with the keys \"city\" and \"country\".", check: .all([.jsonKeys(["city", "country"]), .contains(["Paris"])])),
    BenchTask(id: "inst-reverse", category: "instruction", prompt: "Reverse the string 'abc'. Output only the result.", check: .exact("cba")),
    BenchTask(id: "inst-count", category: "instruction", prompt: "Output the numbers 1 to 5 separated by single spaces, and nothing else.", check: .exact("1 2 3 4 5")),
    // classification
    BenchTask(id: "class-pos", category: "classification", prompt: "Classify the sentiment of this review as positive, negative, or neutral. Answer with one word.\n\nReview: I absolutely loved this movie, easily the best thing I've seen all year!", check: .contains(["positive"])),
    BenchTask(id: "class-neg", category: "classification", prompt: "Classify the sentiment of this review as positive, negative, or neutral. Answer with one word.\n\nReview: The service was terrible and the food arrived cold.", check: .contains(["negative"])),
    BenchTask(id: "class-lang", category: "classification", prompt: "Which language is this sentence written in? Answer with the language name only.\n\nBonjour, comment allez-vous aujourd'hui ?", check: .contains(["French"])),
    BenchTask(id: "class-spam", category: "classification", prompt: "Is the following message spam or not spam? Answer with 'spam' or 'not spam'.\n\nCongratulations!!! You have WON $1,000,000. Click here NOW to claim your prize!", check: .regex(#"^\W*spam"#)),
    // extraction
    BenchTask(id: "extract-email", category: "extraction", prompt: "Extract the email address from this text and output only the address:\n\n'Contact us at support@example.com for help.'", check: .exact("support@example.com")),
    BenchTask(id: "extract-date", category: "extraction", prompt: "Extract the date from this text and output it only in YYYY-MM-DD format:\n\n'The meeting is on March 5, 2024 at noon.'", check: .contains(["2024-03-05"])),
    BenchTask(id: "extract-person-generable", category: "extraction", prompt: "Extract the person's information from this sentence: 'Taro Yamada, 34, lives in Osaka and works as an engineer.'", check: .containsAll(["yamada", "age=34", "osaka"]), structured: .person),
    BenchTask(id: "class-sentiment-generable", category: "classification", prompt: "Classify the sentiment of this review: 'Meh. It works, nothing special, nothing terrible.'", check: .contains(["neutral"]), structured: .sentiment),
    // translation
    BenchTask(id: "trans-en-ja", category: "translation", prompt: "Translate to Japanese: 'Good morning'. Output only the translation.", check: .contains(["おはよう"])),
    BenchTask(id: "trans-ja-en", category: "translation", prompt: "Translate to English: 'ありがとうございます'. Output only the translation.", check: .contains(["thank"])),
    BenchTask(id: "trans-en-fr", category: "translation", prompt: "Translate to French: 'I love cats'. Output only the translation.", check: .contains(["chats"])),
    // japanese
    BenchTask(id: "ja-word", category: "japanese", prompt: "「猫」を英語で言うと何ですか？英単語のみで答えてください。", check: .contains(["cat"])),
    BenchTask(id: "ja-summary", category: "japanese", prompt: "次の文章を一文で要約してください。\n\n昨日、東京で大きな雷雨がありました。多くの電車が止まり、通勤客は駅で長時間待たされました。夕方には天気が回復し、運転も再開されました。", check: .all([.contains(["雷雨", "雷", "嵐", "雨"]), .contains(["電車", "運転", "交通", "列車"])])),
    BenchTask(id: "ja-digits", category: "japanese", prompt: "1から5までの数字を半角数字でカンマ区切りで出力してください。他の文字は出力しないでください。", check: .regex(#"1,\s?2,\s?3,\s?4,\s?5"#)),
    // summarization
    BenchTask(id: "summ-photo", category: "summarization", prompt: "Summarize the following in one sentence of at most 25 words.\n\nPhotosynthesis is the process by which green plants use sunlight to synthesize nutrients from carbon dioxide and water. It generally involves the green pigment chlorophyll and generates oxygen as a by-product. The process takes place mainly in the leaves. Without it, most life on Earth could not exist.", check: .all([.contains(["plant", "photosynthesis"]), .contains(["sunlight", "light"]), .wordCountMax(32)])),
    // code
    BenchTask(id: "code-write", category: "code", prompt: "Write a Python function named add that takes two arguments a and b and returns their sum. Output only the code.", check: .containsAll(["def add", "return"])),
    BenchTask(id: "code-eval", category: "code", prompt: "What does this Python code print? Answer with just the output.\n\nprint(len('hello'))", check: .number(5, tolerance: 0)),
    BenchTask(id: "code-fix", category: "code", prompt: "Fix the syntax error in this Python code and output only the corrected code:\n\nfor i in range(10) print(i)", check: .regex(#"range\(10\)\s*:"#)),
]

// MARK: - Custom task file (JSONL)

struct TaskFileEntry: Decodable {
    struct CheckSpec: Decodable {
        let type: String
        var values: [String]? = nil
        var value: Double? = nil
        var tolerance: Double? = nil
        var pattern: String? = nil
        var max: Int? = nil
        var keys: [String]? = nil
        var checks: [CheckSpec]? = nil

        func toCheck() throws -> Check {
            switch type {
            case "contains": return .contains(values ?? [])
            case "containsAll": return .containsAll(values ?? [])
            case "regex": return .regex(pattern ?? "")
            case "exact": return .exact(values?.first ?? "")
            case "number": return .number(value ?? 0, tolerance: tolerance ?? 0)
            case "wordCountMax": return .wordCountMax(max ?? 0)
            case "jsonKeys": return .jsonKeys(keys ?? [])
            case "all": return .all(try (checks ?? []).map { try $0.toCheck() })
            default: throw ValidationError("Unknown check type '\(type)'")
            }
        }
    }
    let id: String
    var category: String? = nil
    let prompt: String
    var instructions: String? = nil
    let check: CheckSpec
}

func loadTasks(path: String) throws -> [BenchTask] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var tasks: [BenchTask] = []
    for (i, line) in text.split(separator: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        do {
            let e = try JSONDecoder().decode(TaskFileEntry.self, from: Data(line.utf8))
            tasks.append(BenchTask(id: e.id, category: e.category ?? "custom", prompt: e.prompt, instructions: e.instructions, check: try e.check.toCheck()))
        } catch {
            throw ValidationError("\(path):\(i + 1): \(error)")
        }
    }
    return tasks
}

// MARK: - Command

struct Accuracy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a task suite with automatic scoring (built-in suite or a JSONL file).",
        discussion: """
        JSONL format (one object per line):
          {"id":"t1","category":"custom","prompt":"...","instructions":"...",
           "check":{"type":"contains","values":["a","b"]}}
        check.type: contains | containsAll | regex(pattern) | exact(values[0]) | number(value,tolerance)
                    | wordCountMax(max) | jsonKeys(keys) | all(checks)
        """
    )

    @OptionGroup var model: ModelOptions

    @Option(name: .long, help: "Repetitions per task (score is averaged)")
    var runs: Int = 1

    @Option(name: .long, help: "JSONL file with custom tasks (replaces the built-in suite)")
    var tasks: String?

    @Option(name: .long, help: "Only run tasks in this category")
    var category: String?

    @Option(name: .long, help: "Only run the task with this id")
    var id: String?

    @Option(name: .customLong("response-tokens"), help: "maximumResponseTokens per task")
    var responseTokens: Int = 256

    @Flag(name: .long, help: "List tasks and exit")
    var list = false

    @Flag(name: .long, help: "Print model output for every task")
    var verbose = false

    @Flag(name: .long, help: "Emit JSON")
    var json = false

    @OptionGroup var save: SaveOptions

    func run() async throws {
        enableLineBuffering()
        var suite = try tasks.map(loadTasks) ?? builtinTasks
        if let category { suite = suite.filter { $0.category == category } }
        if let id { suite = suite.filter { $0.id == id } }
        if suite.isEmpty { throw ValidationError("No tasks selected.") }

        if list {
            printTable(header: ["id", "category", "check"], rows: suite.map { [$0.id, $0.category, $0.check.describe] })
            return
        }

        try requireAvailable(try model.makeModel())
        // Only the full built-in suite is comparable across machines, so only that gets recorded.
        let isFullSuite = tasks == nil && category == nil && id == nil
        var store: BenchStore? = nil
        if isFullSuite {
            store = try BenchStore.prepare(kind: "accuracy", opts: save, quiet: json)
        } else if !save.noSave && !json {
            print("note: filtered/custom task runs are not recorded in the benchmarks file.")
        }
        // Greedy by default for reproducibility unless the user picked a sampling mode.
        let forced: GenerationOptions.SamplingMode?? = model.sampling == "default" ? .some(.greedy) : nil
        let options = try model.makeGenerationOptions(maxTokens: responseTokens, forceSampling: forced)

        var results: [[String: Any]] = []
        var rows: [[String]] = []
        let sw = Stopwatch()
        for task in suite {
            var scores: [Double] = []
            var times: [Double] = []
            var outputs: [String] = []
            var errors: [String] = []
            for _ in 0..<runs {
                let session = try model.makeSession(instructions: task.instructions ?? model.instructions)
                let t = Stopwatch()
                var out = ""
                var err: String? = nil
                do {
                    switch task.structured {
                    case .none:
                        out = try await session.respond(to: task.prompt, options: options).content
                    case .person:
                        let p = try await session.respond(to: task.prompt, generating: PersonInfo.self, options: options).content
                        out = "name=\(p.name);age=\(p.age);city=\(p.city)"
                    case .sentiment:
                        let s = try await session.respond(to: task.prompt, generating: SentimentLabel.self, options: options).content
                        out = "\(s)"
                    }
                } catch {
                    let (k, d) = describeError(error)
                    err = "\(k): \(d)"
                }
                times.append(t.elapsed)
                outputs.append(out)
                if let err { errors.append(err); scores.append(0) } else { scores.append(task.check.score(out)) }
            }
            let score = mean(scores)
            let r: [String: Any] = ["id": task.id, "category": task.category, "score": score, "latency_s_mean": mean(times),
                                    "outputs": outputs, "errors": errors, "check": task.check.describe]
            results.append(r)
            let status = score >= 1 ? "PASS" : (score > 0 ? "PART" : "FAIL")
            rows.append([task.id, task.category, status, fmtNum(score, 2), fmtMS(mean(times)),
                         errors.isEmpty ? oneLine(outputs.first ?? "", max: 60) : oneLine(errors.first!, max: 60)])
            if !json {
                print("[\(status)] \(task.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(fmtMS(mean(times)))" + (verbose || score < 1 ? "\n       → \(oneLine(outputs.first ?? errors.first ?? "", max: 160))\n       ✓ \(task.check.describe)" : ""))
            }
        }
        let wall = sw.elapsed

        // Aggregate per category
        var byCat: [String: (sum: Double, n: Int, lat: Double)] = [:]
        for r in results {
            let c = r["category"] as! String
            var e = byCat[c] ?? (0, 0, 0)
            e.sum += r["score"] as! Double; e.n += 1; e.lat += r["latency_s_mean"] as! Double
            byCat[c] = e
        }
        let overall = mean(results.map { $0["score"] as! Double })
        let catRows = byCat.keys.sorted().map { c -> [String: Any] in
            let e = byCat[c]!
            return ["category": c, "accuracy": e.sum / Double(e.n), "tasks": e.n, "latency_s_mean": e.lat / Double(e.n)]
        }

        let report: [String: Any] = ["options": model.summary, "runs": runs, "responseTokens": responseTokens, "overallAccuracy": overall,
                                     "taskCount": results.count, "wall_s": wall, "categories": catRows, "tasks": results]
        try store?.save(result: report, options: model.summary)
        if json { printJSON(report); return }

        printSection("Accuracy by category")
        printTable(header: ["category", "accuracy", "tasks", "mean latency"],
                   rows: catRows.map { ["\($0["category"]!)", fmtNum(($0["accuracy"] as! Double) * 100, 0) + "%", "\($0["tasks"]!)", fmtMS($0["latency_s_mean"] as? Double)] })
        print("\n  Overall: \(fmtNum(overall * 100, 1))% over \(results.count) tasks × \(runs) run(s); wall time \(fmtNum(wall, 1)) s")
        let failed = results.filter { ($0["score"] as! Double) < 1 }
        if !failed.isEmpty {
            printSection("Failed / partial tasks")
            printTable(header: ["id", "category", "status", "score", "latency", "first output"],
                       rows: rows.filter { $0[2] != "PASS" })
        }
    }
}
