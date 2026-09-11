import ArgumentParser
import Foundation
import FoundationModels

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show attributes of the on-device Foundation Model and its runtime."
    )

    @OptionGroup var model: ModelOptions

    @Flag(name: .long, help: "Also load the model: measure memory footprint, inspect the transcript, and ask the model about itself")
    var deep = false

    @Flag(name: .long, help: "Emit JSON")
    var json = false

    static let assetDirs = [
        "com_apple_MobileAsset_UAF_FM_GenerativeModels",
        "com_apple_MobileAsset_UAF_FM_Overrides",
        "com_apple_MobileAsset_UAF_FM_CodeLM",
        "com_apple_MobileAsset_UAF_FM_Visual",
    ]

    func run() async throws {
        enableLineBuffering()
        var report: [String: Any] = [:]

        // ---- Host
        let memBytes = Double(Sys.sysctlInt("hw.memsize") ?? 0)
        let host: [String: Any] = [
            "machine": Sys.sysctlString("hw.model") ?? "?",
            "chip": Sys.sysctlString("machdep.cpu.brand_string") ?? "?",
            "cpuCores": Int(Sys.sysctlInt("hw.ncpu") ?? 0),
            "memoryGB": memBytes / 1_073_741_824,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "osBuild": Sys.sysctlString("kern.osversion") ?? "?",
        ]
        report["host"] = host

        // ---- Framework & inference provider versions
        let fwPath = "/System/Library/Frameworks/FoundationModels.framework"
        let fwInfo = Bundle(path: fwPath)?.infoDictionary ?? [:]
        let appexPath = "/System/Library/ExtensionKit/Extensions/TGOnDeviceInferenceProviderService.appex"
        let appexInfo = Bundle(path: appexPath)?.infoDictionary ?? [:]
        let framework: [String: Any] = [
            "path": fwPath,
            "version": fwInfo["CFBundleVersion"] as? String ?? "?",
            "shortVersion": fwInfo["CFBundleShortVersionString"] as? String ?? "?",
            "builtWithSDK": fwInfo["DTPlatformVersion"] as? String ?? "?",
            "inferenceProvider": appexInfo["CFBundleIdentifier"] as? String ?? "(not found)",
            "inferenceProviderExtensionPoint": (appexInfo["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String ?? "?",
        ]
        report["framework"] = framework

        // ---- Apple Intelligence opt-in (preferences domain)
        var optIn: [String: Any] = [:]
        if let defaults = UserDefaults(suiteName: "com.apple.CloudSubscriptionFeatures.optIn") {
            for key in ["auto_opt_in", "opted_in_buddy"] {
                if let v = defaults.object(forKey: key) { optIn[key] = v }
            }
        }
        report["appleIntelligenceOptIn"] = optIn

        // ---- Model availability
        let general = SystemLanguageModel.default
        let tagging = SystemLanguageModel(useCase: .contentTagging)
        let permissive = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let langs = general.supportedLanguages.map { $0.minimalIdentifier }.sorted()
        let en = Locale(identifier: "en_US")
        let langNames = langs.map { "\($0) (\(en.localizedString(forIdentifier: $0) ?? "?"))" }
        var modelInfo: [String: Any] = [
            "availability.general": describeAvailability(general.availability),
            "availability.contentTagging": describeAvailability(tagging.availability),
            "availability.general+permissiveGuardrails": describeAvailability(permissive.availability),
            "supportedLanguageCount": langs.count,
            "supportedLanguages": langNames,
            "useCases": ["general", "contentTagging"],
            "guardrails": ["default", "permissiveContentTransformations"],
            "generationErrors": ["exceededContextWindowSize", "assetsUnavailable", "guardrailViolation", "unsupportedGuide",
                                 "unsupportedLanguageOrLocale", "decodingFailure", "rateLimited", "concurrentRequests", "refusal"],
        ]

        // ---- Model assets on disk
        var assets: [[String: Any]] = []
        let fm = FileManager.default
        for name in Self.assetDirs {
            let path = "/System/Library/AssetsV2/" + name
            var entry: [String: Any] = ["name": name, "path": path]
            if fm.fileExists(atPath: path) {
                entry["present"] = true
                if let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date {
                    entry["modified"] = ISO8601DateFormatter().string(from: date)
                }
                do {
                    let items = try fm.contentsOfDirectory(atPath: path)
                    entry["readable"] = true
                    entry["entries"] = items
                } catch {
                    entry["readable"] = false
                    entry["note"] = "protected by TCC; grant Full Disk Access to the terminal to inspect"
                }
            } else {
                entry["present"] = false
            }
            assets.append(entry)
        }
        report["assets"] = assets

        // ---- Inference stack processes
        let procs = Sys.inferenceProcesses()
        report["inferenceProcesses"] = procs.map { ["pid": Int($0.pid), "name": $0.name, "rss_mb": Double($0.rssKB) / 1024] as [String: Any] }

        // ---- Public documentation (not observed on this machine)
        report["publicDocumentation"] = [
            "note": "From Apple's published material (Foundation Models docs / Apple Intelligence Foundation Language Models Tech Report 2025). Not measured here.",
            "onDeviceModel": "~3B-parameter dense transformer (Apple: 'approximately 3 billion parameters')",
            "weights": "2-bit quantization-aware training; embeddings ~4-bit; KV cache ~8-bit (tech report)",
            "contextWindow": "4,096 tokens shared by instructions + prompt + response (use `fmbench probe context` to measure)",
            "adapters": "LoRA adapters trainable with Apple's adapter training toolkit; loaded via SystemLanguageModel(adapter:)",
            "execution": "Runs out-of-process in TGOnDeviceInferenceProviderService (ExtensionKit) via modelmanagerd; guardrails run in GenerativeExperiencesSafetyInferenceProvider",
        ]

        // ---- Deep probes
        if deep {
            try requireAvailable(try model.makeModel())
            let sampler = RSSSampler()
            sampler.recordBaseline()
            sampler.start()

            let session = try model.makeSession()
            let load = Stopwatch()
            session.prewarm()
            let first = await streamGenerate(session: session, prompt: "Reply with the single word: ready",
                                             options: try model.makeGenerationOptions(maxTokens: 8, forceSampling: .some(.greedy)))
            let loadTime = load.elapsed
            await sampler.stop()

            var deepInfo: [String: Any] = [
                "coldFirstResponse_s": loadTime,
                "coldTTFT_s": first.ttft ?? -1,
                "firstResponse": first.text,
                "memory": sampler.report,
            ]
            if let e = first.error { deepInfo["firstResponseError"] = e }

            // Transcript inspection: what does the framework record?
            var entries: [String] = []
            for entry in session.transcript {
                switch entry {
                case .instructions: entries.append("instructions")
                case .prompt(let p): entries.append("prompt(options: \(p.options))")
                case .response(let r): entries.append("response(\(r.segments.count) segment(s))")
                case .toolCalls: entries.append("toolCalls")
                case .toolOutput: entries.append("toolOutput")
                @unknown default: entries.append("unknown")
                }
            }
            deepInfo["transcriptEntries"] = entries

            // Self-report (unreliable: models often confabulate about themselves)
            let questions = [
                "Which company created you, and what is the name of the model you are? Answer in one sentence.",
                "What is your training data cutoff date? Answer briefly.",
                "How many parameters do you have? Answer with your best guess in one short sentence.",
                "あなたは日本語で会話できますか？一文で答えてください。",
            ]
            var selfReport: [[String: String]] = []
            for q in questions {
                let s = try model.makeSession()
                let r = await streamGenerate(session: s, prompt: q,
                                             options: try model.makeGenerationOptions(maxTokens: 80, forceSampling: .some(.greedy)))
                selfReport.append(["question": q, "answer": r.ok ? r.text : "ERROR: \(r.error ?? "?")"])
            }
            deepInfo["selfReport"] = selfReport
            deepInfo["selfReportNote"] = "Self-descriptions from a small on-device model are frequently wrong; treat as curiosity, not fact."
            report["deep"] = deepInfo
            modelInfo["measured"] = true
        }
        report["model"] = modelInfo

        if json { printJSON(report); return }

        // ---- Human-readable output
        printSection("Host")
        printKV([
            ("Machine", "\(host["machine"]!)"),
            ("Chip", "\(host["chip"]!)"),
            ("CPU cores", "\(host["cpuCores"]!)"),
            ("Memory", String(format: "%.0f GB", memBytes / 1_073_741_824)),
            ("macOS", "\(host["os"]!)"),
        ])
        printSection("FoundationModels.framework")
        printKV([
            ("Version", "\(framework["shortVersion"]!) (build \(framework["version"]!), SDK \(framework["builtWithSDK"]!))"),
            ("Inference provider", "\(framework["inferenceProvider"]!)"),
            ("Extension point", "\(framework["inferenceProviderExtensionPoint"]!)"),
            ("AI opt-in prefs", optIn.isEmpty ? "(not readable)" : optIn.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")),
        ])
        printSection("SystemLanguageModel")
        printKV([
            ("general", describeAvailability(general.availability)),
            ("contentTagging", describeAvailability(tagging.availability)),
            ("permissive guardrails", describeAvailability(permissive.availability)),
            ("Languages (\(langs.count))", langNames.joined(separator: "\n")),
        ])
        if let hint = availabilityHint(general.availability) {
            print("")
            print(hint.split(separator: "\n").map { "  ! " + $0 }.joined(separator: "\n"))
        }
        printSection("Model assets (MobileAsset)")
        printKV(assets.map { a in
            let present = a["present"] as? Bool ?? false
            var status = present ? "present" : "missing"
            if present {
                status += (a["readable"] as? Bool ?? false) ? ", readable" : ", protected (TCC)"
                if let m = a["modified"] as? String { status += ", modified \(m)" }
                if let items = a["entries"] as? [String], !items.isEmpty { status += "\n" + items.joined(separator: "\n") }
            }
            return ("\(a["name"]!)", status)
        })
        printSection("Inference stack processes (now)")
        if procs.isEmpty { print("  (none running)") }
        printKV(procs.map { p in (p.name, String(format: "pid %d, RSS %.1f MB", p.pid, Double(p.rssKB) / 1024)) })

        if let deepInfo = report["deep"] as? [String: Any] {
            printSection("Deep: load & memory")
            printKV([
                ("Cold first response", fmtMS(deepInfo["coldFirstResponse_s"] as? Double)),
                ("Cold TTFT", fmtMS(deepInfo["coldTTFT_s"] as? Double)),
                ("Response", oneLine(deepInfo["firstResponse"] as? String ?? "")),
            ])
            if let mem = deepInfo["memory"] as? [[String: Any]] {
                printTable(header: ["process", "baseline MB", "peak MB", "delta MB"],
                           rows: mem.map { [
                               "\($0["process"]!)",
                               fmtNum($0["baseline_rss_mb"] as? Double),
                               fmtNum($0["peak_rss_mb"] as? Double),
                               fmtNum($0["delta_mb"] as? Double),
                           ] })
            }
            printSection("Deep: transcript entries")
            for e in deepInfo["transcriptEntries"] as? [String] ?? [] { print("  - \(e)") }
            print("  (The dumped GenerationOptions reveal non-public fields such as repetition, length, stopSequences, allowsUnsupportedLanguagesInPrompt.)")
            printSection("Deep: self-report (unreliable)")
            for qa in deepInfo["selfReport"] as? [[String: String]] ?? [] {
                print("  Q: \(qa["question"]!)")
                print("  A: \(oneLine(qa["answer"]!, max: 200))")
            }
        }

        printSection("Public documentation (not measured)")
        printKV((report["publicDocumentation"] as! [String: String]).sorted(by: { $0.key < $1.key }).filter { $0.key != "note" })
        if !deep { print("\n  Tip: `fmbench info --deep` loads the model and measures memory footprint; `fmbench probe context` measures the context window.") }
    }
}
