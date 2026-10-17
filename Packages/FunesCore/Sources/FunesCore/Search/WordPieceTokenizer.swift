import Foundation

/// BERT uncased WordPiece, as Hugging Face's `BertTokenizer` does it for bge-small-en-v1.5: clean
/// the text, lowercase, strip accents, split on whitespace, punctuation and CJK characters, then
/// greedy longest-match subwords. Ported from Spike 2b; it must produce Hugging Face's ids for
/// every fixture text (`tokenizer-bge-small.json`).
public struct WordPieceTokenizer: Sendable {
    let vocab: [String: Int32]
    public let cls: Int32
    public let sep: Int32
    public let unk: Int32

    public enum LoadError: Error { case missingSpecialTokens }

    /// `vocab.txt`: one token per line; the line number is the id.
    public init(vocabURL: URL) throws {
        let text = try String(contentsOf: vocabURL, encoding: .utf8)
        var v: [String: Int32] = [:]
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            v[String(line)] = Int32(i)
        }
        guard let cls = v["[CLS]"], let sep = v["[SEP]"], let unk = v["[UNK]"] else { throw LoadError.missingSpecialTokens }
        vocab = v
        self.cls = cls
        self.sep = sep
        self.unk = unk
    }

    /// `[CLS] tokens… [SEP]`, at most `maxLength` ids (the tokens are truncated, not the markers).
    public func encode(_ text: String, maxLength: Int = 256) -> [Int32] {
        let ids = basicTokens(text).flatMap(wordpiece)
        return [cls] + ids.prefix(max(0, maxLength - 2)) + [sep]
    }

    func basicTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        // BertTokenizer cleans and splits CJK before lowercasing and stripping accents per word;
        // for this vocabulary the order doesn't change the result on any fixture text.
        for s in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD { continue }
            let category = s.properties.generalCategory
            if category == .nonspacingMark { continue }  // strip accents
            if s == " " || s == "\t" || s == "\n" || s == "\r" || category == .spaceSeparator {
                flush()
                continue
            }
            if category == .control || category == .format { continue }
            if Self.isPunctuation(s) || Self.isCJK(s) {
                flush()
                tokens.append(String(s))
                continue
            }
            current.unicodeScalars.append(s)
        }
        flush()
        return tokens
    }

    func wordpiece(_ word: String) -> [Int32] {
        let chars = Array(word.unicodeScalars)
        if chars.count > 100 { return [unk] }
        var out: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32?
            while start < end {
                var piece = String(String.UnicodeScalarView(chars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] {
                    found = id
                    break
                }
                end -= 1
            }
            guard let id = found else { return [unk] }
            out.append(id)
            start = end
        }
        return out
    }

    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let c = s.value
        if (33...47).contains(c) || (58...64).contains(c) || (91...96).contains(c) || (123...126).contains(c) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let c = s.value
        return (0x4E00...0x9FFF).contains(c) || (0x3400...0x4DBF).contains(c) || (0x20000...0x2A6DF).contains(c)
            || (0x2A700...0x2B73F).contains(c) || (0x2B740...0x2B81F).contains(c) || (0x2B820...0x2CEAF).contains(c)
            || (0xF900...0xFAFF).contains(c) || (0x2F800...0x2FA1F).contains(c)
    }
}
