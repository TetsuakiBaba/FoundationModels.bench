import ArgumentParser
import Foundation

let fmbenchRepo = "TetsuakiBaba/FoundationModels.bench"

/// Share recorded results without cloning the repository: opens a prefilled GitHub Issue
/// (or creates it directly via `gh`). A GitHub Action merges the JSON into benchmarks.json.
struct Submit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Share your recorded results (benchmarks.json) as a GitHub Issue — no clone / PR needed.",
        discussion: """
        Picks the entry for this machine from the benchmarks file and submits it:
          1. If the GitHub CLI (`gh`) is installed and logged in, the issue is created directly.
          2. Otherwise the JSON is copied to the clipboard and a prefilled issue form opens in
             your browser — paste (Cmd+V) into the "Result JSON" box and press "Submit new issue".
        A maintainer bot turns the issue into a pull request against benchmarks.json.
        """
    )

    @Option(name: .customLong("benchmarks-file"), help: "Results file to read")
    var file: String = "benchmarks.json"

    @Flag(name: .long, help: "Submit every entry in the file, not just this machine's")
    var all = false

    @Flag(name: .long, help: "Always use the browser flow, even if `gh` is available")
    var browser = false

    @Flag(name: .customLong("dry-run"), help: "Print the JSON and the URL without opening anything")
    var dryRun = false

    @Option(name: .long, help: "GitHub repository to submit to (owner/name)")
    var repo: String = fmbenchRepo

    func run() throws {
        let entries = try loadEntries()
        let env = Environment.capture()
        let selected: [[String: Any]]
        if all {
            selected = entries
        } else {
            let key = Environment.key(env)
            guard let mine = entries.first(where: { ($0["key"] as? String) == key }) else {
                print("No result for this machine configuration found in \(file).")
                print("  expected key: \(key)")
                if entries.isEmpty {
                    print("Run a benchmark first, e.g.:  fmbench bench speed")
                } else {
                    print("The file has \(entries.count) other entr\(entries.count == 1 ? "y" : "ies"); use --all to submit them all.")
                }
                throw ExitCode(1)
            }
            selected = [mine]
        }
        guard !selected.isEmpty else {
            print("\(file) has no entries. Run a benchmark first, e.g.:  fmbench bench speed")
            throw ExitCode(1)
        }

        let payload: Any = selected.count == 1 ? selected[0] : selected
        // Already JSON (read from disk) — do not pass through sanitizeForJSON, it would turn Bool NSNumbers into 1/0.
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let json = String(decoding: data, as: UTF8.self)
        let kinds = selected.flatMap { ($0["benchmarks"] as? [String: Any])?.keys.sorted() ?? [] }
        let title = all
            ? "bench: \(selected.count) entries from \(env["machine"] ?? "?")"
            : "bench: \(env["chip"] ?? "?"), \(env["machine"] ?? "?"), macOS \(env["osVersion"] ?? "?")"

        printSection("Submitting")
        printKV([("file", file), ("entries", "\(selected.count)"), ("benchmarks", kinds.joined(separator: ", ")),
                 ("title", title), ("size", "\(data.count) bytes")])

        if dryRun {
            print(json)
            print(issueURL(title: title, json: json).absoluteString)
            return
        }

        if !browser, let url = try createWithGH(title: title, json: json) {
            print("\nCreated \(url)")
            print("Thanks! A bot will open a pull request that adds your result to benchmarks.json.")
            return
        }

        // Browser flow
        let url = issueURL(title: title, json: json)
        let inlined = url.query?.contains("entry=") ?? false
        if !inlined { copyToClipboard(json) }
        _ = Sys.shell("/usr/bin/open", [url.absoluteString])
        print("")
        print("Opened the GitHub issue form in your browser (sign in if asked).")
        if inlined {
            print("  1. Check the prefilled \"Result JSON\" box")
        } else {
            print("  1. Paste the clipboard (Cmd+V) into the \"Result JSON\" box — the JSON has been copied for you")
        }
        print("  2. Press \"Submit new issue\"")
        print("A bot will open a pull request that adds your result to benchmarks.json.")
        print("If the browser did not open, go to:\n  \(url.absoluteString)")
    }

    // MARK: - helpers

    private func loadEntries() throws -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: file) else {
            print("\(file) not found. Run a benchmark in this directory first, e.g.:  fmbench bench speed")
            throw ExitCode(1)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            throw ValidationError("\(file) is not a benchmarks file (missing \"entries\")")
        }
        return entries
    }

    /// Issue-form URL. The JSON is inlined only when the URL stays short enough for GitHub.
    private func issueURL(title: String, json: String) -> URL {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        let items = [URLQueryItem(name: "template", value: "benchmark-result.yml"),
                     URLQueryItem(name: "title", value: title)]
        let withEntry = items + [URLQueryItem(name: "entry", value: json)]
        c.queryItems = withEntry
        if (c.url?.absoluteString.count ?? .max) <= 6000 { return c.url! }
        c.queryItems = items
        return c.url!
    }

    private func issueBody(json: String) -> String {
        // Mirrors what the issue form renders, so the ingest workflow parses both the same way.
        """
        ### Result JSON

        ```json
        \(json)
        ```

        ### Notes

        _Submitted with `fmbench submit \(fmbenchVersion)`._
        """
    }

    /// Returns the issue URL when `gh` is installed and authenticated; nil to fall back to the browser.
    private func createWithGH(title: String, json: String) throws -> String? {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? which("gh") else { return nil }
        let auth = Process()
        auth.executableURL = URL(fileURLWithPath: gh)
        auth.arguments = ["auth", "status"]
        auth.standardOutput = FileHandle.nullDevice
        auth.standardError = FileHandle.nullDevice
        try auth.run(); auth.waitUntilExit()
        guard auth.terminationStatus == 0 else { return nil }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fmbench-submit-\(UUID().uuidString).md")
        try issueBody(json: json).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["issue", "create", "--repo", repo, "--title", title, "--body-file", tmp.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            print("note: `gh issue create` failed (exit \(p.terminationStatus)); falling back to the browser.")
            return nil
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func which(_ name: String) -> String? {
        let s = Sys.shell("/usr/bin/which", [name]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func copyToClipboard(_ s: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let inPipe = Pipe()
        p.standardInput = inPipe
        do {
            try p.run()
            inPipe.fileHandleForWriting.write(Data(s.utf8))
            try inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
        } catch {
            print("note: could not copy to clipboard (\(error.localizedDescription))")
        }
    }
}
