import ArgumentParser
import Foundation
import FoundationModels

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a single prompt, stream the output, and print timing stats.")

    @OptionGroup var model: ModelOptions

    @Argument(help: "Prompt text (use '-' to read from stdin)")
    var prompt: String

    @Flag(name: .long, help: "Emit JSON instead of streaming text")
    var json = false

    @Flag(name: .customLong("no-stream"), help: "Use respond() instead of streamResponse()")
    var noStream = false

    func run() async throws {
        enableLineBuffering()
        try requireAvailable(try model.makeModel())
        var text = prompt
        if prompt == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        let session = try model.makeSession()
        let options = try model.makeGenerationOptions()

        if noStream || json {
            let r = noStream ? await generate(session: session, prompt: text, options: options)
                             : await streamGenerate(session: session, prompt: text, options: options)
            if json {
                var d = r.dict
                d["text"] = r.text
                printJSON(d)
            } else {
                print(r.text)
                if let e = r.error { print("ERROR (\(r.errorKind ?? "?")): \(e)") }
                print("\n-- total \(fmtMS(r.total)), \(r.text.count) chars")
            }
            return
        }

        // Streaming: print incremental deltas as they arrive.
        var r = GenResult()
        let sw = Stopwatch()
        var printed = 0
        do {
            for try await snap in session.streamResponse(to: text, options: options) {
                if r.ttft == nil { r.ttft = sw.elapsed }
                r.chunks += 1
                r.text = snap.content
                if r.text.count >= printed {
                    let delta = String(r.text.dropFirst(printed))
                    FileHandle.standardOutput.write(Data(delta.utf8))
                    printed = r.text.count
                }
            }
        } catch {
            let (k, d) = describeError(error); r.errorKind = k; r.error = d
        }
        r.total = sw.elapsed
        print("")
        if let e = r.error { print("ERROR (\(r.errorKind ?? "?")): \(e)") }
        print("-- TTFT \(fmtMS(r.ttft)), total \(fmtMS(r.total)), \(r.chunks) chunks, \(r.text.count) chars, ≈\(fmtNum(r.chunksPerSecond)) chunks/s, \(fmtNum(r.charsPerSecond, 0)) chars/s")
    }
}
