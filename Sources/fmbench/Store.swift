import ArgumentParser
import Foundation
import FoundationModels

let fmbenchVersion = "0.2.0"

// MARK: - Environment fingerprint

enum Environment {
    /// Hardware + software facts that determine benchmark results. `key` is built from the subset
    /// that must match exactly for two runs to be considered "the same machine configuration".
    static func capture() -> [String: Any] {
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let fwInfo = Bundle(path: "/System/Library/Frameworks/FoundationModels.framework")?.infoDictionary ?? [:]
        var assetsModified = "unknown"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels"),
           let d = attrs[.modificationDate] as? Date {
            assetsModified = ISO8601DateFormatter().string(from: d)
        }
        return [
            "machine": Sys.sysctlString("hw.model") ?? "?",
            "chip": Sys.sysctlString("machdep.cpu.brand_string") ?? "?",
            "cpuCores": Int(Sys.sysctlInt("hw.ncpu") ?? 0),
            "memoryGB": Int((Double(Sys.sysctlInt("hw.memsize") ?? 0) / 1_073_741_824).rounded()),
            "osVersion": "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
            "osBuild": Sys.sysctlString("kern.osversion") ?? "?",
            "frameworkBuild": fwInfo["CFBundleVersion"] as? String ?? "?",
            "modelAssetsModified": assetsModified,
            "supportedLanguageCount": SystemLanguageModel.default.supportedLanguages.count,
            "fmbenchVersion": fmbenchVersion,
        ]
    }

    static let keyFields = ["machine", "chip", "memoryGB", "osVersion", "osBuild", "frameworkBuild", "modelAssetsModified"]

    static func key(_ env: [String: Any]) -> String {
        keyFields.map { "\(env[$0] ?? "?")" }.joined(separator: " | ")
    }
}

// MARK: - CLI options

struct SaveOptions: ParsableArguments {
    @Flag(name: .customLong("no-save"), help: "Do not record the result in the benchmarks file")
    var noSave = false

    @Flag(name: .long, help: "Overwrite an existing result for this machine configuration without asking")
    var force = false

    @Option(name: .customLong("benchmarks-file"), help: "Results file (shared JSON read by index.html)")
    var file: String = "benchmarks.json"
}

// MARK: - Store

struct BenchStore {
    let path: String
    let kind: String
    let env: [String: Any]
    let key: String

    /// Call BEFORE running a benchmark. Returns nil when the result must not be saved.
    /// If a result for this exact configuration exists, asks the user (TTY) whether to overwrite;
    /// declining aborts the run.
    static func prepare(kind: String, opts: SaveOptions, quiet: Bool) throws -> BenchStore? {
        if opts.noSave { return nil }
        let env = Environment.capture()
        let store = BenchStore(path: opts.file, kind: kind, env: env, key: Environment.key(env))
        guard let existing = store.existingResult() else { return store }
        let when = existing["recordedAt"] as? String ?? "?"
        if opts.force {
            if !quiet { print("note: overwriting the existing '\(kind)' result for this machine (recorded \(when)).") }
            return store
        }
        guard isatty(0) != 0 else {
            if !quiet {
                print("note: a '\(kind)' result for this exact machine configuration already exists in \(opts.file) (recorded \(when)).")
                print("      Not saving. Re-run with --force to overwrite, or --no-save to silence this note.")
            }
            return nil
        }
        print("A '\(kind)' benchmark for this exact machine configuration already exists in \(opts.file) (recorded \(when)):")
        print("  \(store.key)")
        print("Running it again will OVERWRITE that entry. Continue? [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else {
            print("Aborted. Use --no-save to run without recording, or --force to overwrite without asking.")
            throw ExitCode(1)
        }
        return store
    }

    func load() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["version": 1, "entries": [[String: Any]]()]
        }
        return obj
    }

    func entryIndex(in entries: [[String: Any]]) -> Int? {
        entries.firstIndex { ($0["key"] as? String) == key }
    }

    func existingResult() -> [String: Any]? {
        let entries = load()["entries"] as? [[String: Any]] ?? []
        guard let i = entryIndex(in: entries) else { return nil }
        return (entries[i]["benchmarks"] as? [String: Any])?[kind] as? [String: Any]
    }

    func save(result: [String: Any], options: [String: Any]) throws {
        var root = load()
        var entries = root["entries"] as? [[String: Any]] ?? []
        let now = ISO8601DateFormatter().string(from: Date())
        let idx = entryIndex(in: entries)
        var entry = idx.map { entries[$0] } ?? ["key": key, "createdAt": now]
        entry["environment"] = env
        entry["updatedAt"] = now
        var benchmarks = entry["benchmarks"] as? [String: Any] ?? [:]
        benchmarks[kind] = ["recordedAt": now, "options": options, "result": result]
        entry["benchmarks"] = benchmarks
        if let idx { entries[idx] = entry } else { entries.append(entry) }
        root["entries"] = entries
        root["version"] = 1
        root["generatedBy"] = "FoundationModels.bench \(fmbenchVersion)"
        let data = try JSONSerialization.data(withJSONObject: sanitizeForJSON(root),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        FileHandle.standardError.write(Data("saved '\(kind)' result for this machine to \(path)\n".utf8))
    }
}
