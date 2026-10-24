// Spike E: embeds texts with FunesCore's bundled bge-small (the Core ML int8 model the app ships).
// Usage: bge-embed <model-dir> <in.json: [String]> <out.json: [[Float]]>. Documents only (no query prefix).
import Foundation
import FunesCore

@main
struct Embed {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            FileHandle.standardError.write("usage: bge-embed <model-dir> <in.json> <out.json>\n".data(using: .utf8)!)
            exit(2)
        }
        let embedder = try BundledBGEEmbedder(directory: URL(fileURLWithPath: args[1]))
        let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let vectors = try await embedder.embed(texts, as: .document)
        try JSONEncoder().encode(vectors).write(to: URL(fileURLWithPath: args[3]))
    }
}
