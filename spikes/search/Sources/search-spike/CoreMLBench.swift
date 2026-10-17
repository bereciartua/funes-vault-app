// Spike 2b: a BERT-style embedder converted to Core ML (spikes/embeddings/convert_coreml.py),
// run from Swift end to end: WordPiece tokenization, prediction, vectors. Run with MODE=coreml.
import CoreML
import Foundation

/// BERT uncased WordPiece, as in Hugging Face's BertTokenizer: clean, lowercase, strip accents,
/// split on whitespace and punctuation, then greedy longest-match subwords.
final class WordPieceTokenizer {
    let vocab: [String: Int32]
    let cls: Int32, sep: Int32, unk: Int32

    init(vocabURL: URL) throws {
        let lines = try String(contentsOf: vocabURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        var v: [String: Int32] = [:]
        for (i, l) in lines.enumerated() where !l.isEmpty { v[String(l)] = Int32(i) }
        vocab = v
        cls = v["[CLS]"]!; sep = v["[SEP]"]!; unk = v["[UNK]"]!
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let c = s.value
        if (33...47).contains(c) || (58...64).contains(c) || (91...96).contains(c) || (123...126).contains(c) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let c = s.value
        return (0x4E00...0x9FFF).contains(c) || (0x3400...0x4DBF).contains(c) || (0x20000...0x2A6DF).contains(c)
            || (0x2A700...0x2B73F).contains(c) || (0x2B740...0x2B81F).contains(c) || (0x2B820...0x2CEAF).contains(c)
            || (0xF900...0xFAFF).contains(c) || (0x2F800...0x2FA1F).contains(c)
    }

    func basicTokens(_ text: String) -> [String] {
        var tokens: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }
        let folded = text.lowercased().decomposedStringWithCanonicalMapping
        for s in folded.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD { continue }
            if s.properties.generalCategory == .nonspacingMark { continue }  // strip accents
            if s == " " || s == "\t" || s == "\n" || s == "\r" || s.properties.generalCategory == .spaceSeparator { flush(); continue }
            if s.properties.generalCategory == .control || s.properties.generalCategory == .format { continue }
            if Self.isPunctuation(s) || Self.isCJK(s) { flush(); tokens.append(String(s)); continue }
            cur.unicodeScalars.append(s)
        }
        flush()
        return tokens
    }

    func wordpiece(_ word: String) -> [Int32] {
        let chars = Array(word.unicodeScalars)
        if chars.count > 100 { return [unk] }
        var out: [Int32] = [], start = 0
        while start < chars.count {
            var end = chars.count, found: Int32? = nil
            while start < end {
                var piece = String(String.UnicodeScalarView(chars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            out.append(id)
            start = end
        }
        return out
    }

    func encode(_ text: String, maxLength: Int = 256) -> [Int32] {
        let ids = basicTokens(text).flatMap(wordpiece)
        return [cls] + ids.prefix(maxLength - 2) + [sep]
    }
}

final class CoreMLEmbedder {
    let model: MLModel
    let tokenizer: WordPieceTokenizer
    let lengths = [16, 32, 64, 128, 256]
    let dims: Int

    init(compiledURL: URL, tokenizer: WordPieceTokenizer, computeUnits: MLComputeUnits) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiledURL, configuration: config)
        self.tokenizer = tokenizer
        dims = 0
    }

    func embed(_ text: String) throws -> [Float] {
        let ids = tokenizer.encode(text)
        let n = lengths.first { $0 >= ids.count }!
        let idArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let maskArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let ip = idArr.dataPointer.bindMemory(to: Int32.self, capacity: n)
        let mp = maskArr.dataPointer.bindMemory(to: Int32.self, capacity: n)
        for i in 0..<n { ip[i] = i < ids.count ? ids[i] : 0; mp[i] = i < ids.count ? 1 : 0 }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": idArr, "attention_mask": maskArr]))
        let e = out.featureValue(for: "embedding")!.multiArrayValue!
        var v = [Float](repeating: 0, count: e.count)
        for i in 0..<e.count { v[i] = e[i].floatValue }
        return l2normalize(v)
    }
}

/// Embeds the exported corpus (EXPORT in MODE=2b) and the three query sets with the Core ML model,
/// writing vectors/<NAME>/ in the same format as embed.py.
@MainActor func runCoreMLBench() async throws {
    let env = ProcessInfo.processInfo.environment
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    let package = URL(fileURLWithPath: env["MLPACKAGE"]!)
    let tokenizer = try WordPieceTokenizer(vocabURL: URL(fileURLWithPath: env["VOCAB"]!))
    let units: MLComputeUnits = switch env["UNITS"] ?? "all" {
    case "cpu": .cpuOnly
    case "gpu": .cpuAndGPU
    case "ane": .cpuAndNeuralEngine
    default: .all
    }
    let qp = env["QPREFIX"] ?? "", dp = env["DPREFIX"] ?? ""
    let out = URL(fileURLWithPath: env["OUT"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    // Tokenizer check against Hugging Face's ids (TOKCHECK: [{"text", "ids"}] from tokcheck.py).
    if let check = env["TOKCHECK"] {
        struct Item: Decodable { let text: String; let ids: [Int32] }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: check)))
        let bad = items.filter { tokenizer.encode($0.text) != $0.ids }
        print("tokenizer check: \(items.count - bad.count)/\(items.count) identical")
        for b in bad.prefix(3) { print("  mismatch: \(b.text.prefix(80))\n   swift \(tokenizer.encode(b.text).prefix(40))\n   hf    \(b.ids.prefix(40))") }
    }

    var t = now()
    let compiled = try await MLModel.compileModel(at: package)
    let compileMs = now() - t
    t = now()
    let embedder = try CoreMLEmbedder(compiledURL: compiled, tokenizer: tokenizer, computeUnits: units)
    let loadMs = now() - t
    t = now()
    _ = try embedder.embed("warm up")
    let firstMs = now() - t

    struct ExportDoc: Decodable { let id: String; let text: String }
    struct Export: Decodable { let docs: [ExportDoc]; let queries: [String: [String]] }
    let corpus = try JSONDecoder().decode(Export.self, from: Data(contentsOf: URL(fileURLWithPath: env["CORPUS"]!)))

    func write(_ vs: [[Float]], _ name: String) throws {
        var flat = vs.flatMap { $0 }
        try Data(bytes: &flat, count: flat.count * 4).write(to: out.appendingPathComponent(name))
    }
    t = now()
    let docVecs = try corpus.docs.map { try embedder.embed(dp + $0.text) }
    let docMs = (now() - t) / Double(corpus.docs.count)
    try write(docVecs, "docs.f32")
    for (set, texts) in corpus.queries { try write(try texts.map { try embedder.embed(qp + $0) }, "q_\(set).f32") }
    var times: [Double] = []
    for _ in 0..<3 {
        for q in corpus.queries["agent"]! {
            let s = now()
            _ = try embedder.embed(qp + q)
            times.append(now() - s)
        }
    }
    times.sort()
    let sizeMB = (FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.fileSizeKey])?.compactMap {
        try? ($0 as? URL)?.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }.reduce(0, +) ?? 0)
    let meta: [String: Any] = [
        "name": env["NAME"]!, "hf_id": env["HF_ID"] ?? "", "dims": docVecs[0].count,
        "runtime": "Core ML from Swift, fp16, computeUnits=\(env["UNITS"] ?? "all"), incl. tokenization",
        "doc_ms": docMs, "query_ms_p50": times[times.count / 2], "query_ms_p95": times[Int(Double(times.count - 1) * 0.95)],
        "size_mb": Double(sizeMB) / 1_048_576, "license": env["LICENSE"] ?? "unknown",
        "compile_ms": compileMs, "load_ms": loadMs, "first_prediction_ms": firstMs,
    ]
    try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("meta.json"))
    print(String(data: try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]), encoding: .utf8)!)
}
