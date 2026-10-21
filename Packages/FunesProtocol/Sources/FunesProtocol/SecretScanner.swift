import Foundation

/// A type of credential the scanner looks for. Only the type is ever reported, never the text.
public enum SecretPattern: String, Codable, Sendable, CaseIterable {
    case privateKey = "private_key"
    case awsAccessKey = "aws_access_key"
    case openAIStyleKey = "openai_style_key"
    case githubToken = "github_token"
    case jwt
    case assignedSecret = "assigned_secret"
    case slackToken = "slack_token"
    case stripeKey = "stripe_key"
    case googleAPIKey = "google_api_key"
    case funesOrEKBKey = "funes_or_ekb_key"
    case creditCard = "credit_card"
}

/// Finds credentials in text so they are never stored or sent anywhere
/// (spec/domain/memory-processing.md#1-secret-scanner, NFR-SEC-06). The Mac and the iPhone run
/// this same code.
public enum SecretScanner {
    /// The pattern types found in `texts`, each once, in `SecretPattern` order. Empty means clean.
    public static func scan(_ texts: [String]) -> [SecretPattern] {
        var found = Set<SecretPattern>()
        for text in texts where !text.isEmpty {
            for (pattern, regex) in compiled where !found.contains(pattern) && matches(regex, pattern, text) {
                found.insert(pattern)
            }
        }
        return SecretPattern.allCases.filter(found.contains)
    }

    public static func scan(_ text: String) -> [SecretPattern] { scan([text]) }

    public static func containsSecret(_ texts: String...) -> Bool { !scan(texts).isEmpty }

    // MARK: - Patterns

    private static let sources: [(SecretPattern, String, NSRegularExpression.Options)] = [
        (.privateKey, #"-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"#, [.caseInsensitive]),
        (.awsAccessKey, #"\b(AKIA|ASIA)[A-Z0-9]{16}\b"#, []),
        (.openAIStyleKey, #"\bsk-[A-Za-z0-9_-]{20,}\b"#, []),
        (.githubToken, #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b"#, []),
        (.jwt, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, []),
        // A value of 12+ characters, or 8+ that mix letters and digits ("1Password" is a product name).
        (.assignedSecret,
         #"\b(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password)\b\s*[:=]\s*["']?"#
             + #"(?:[^"'\s]{12,}|(?!1password\b)(?=[^"'\s]*[A-Za-z])(?=[^"'\s]*[0-9])[^"'\s]{8,})"#,
         [.caseInsensitive]),
        (.slackToken, #"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"#, []),
        (.stripeKey, #"\b(sk|rk)_(live|test)_[A-Za-z0-9]{16,}\b"#, []),
        (.googleAPIKey, #"\bAIza[0-9A-Za-z_-]{35}\b"#, []),
        // MCP keys, remote tokens, and OAuth access, refresh and client-secret tokens.
        (.funesOrEKBKey, #"\b(fns|ekb)_(mcp|mcpr|oat|ort|ocs)_v1_[0-9a-f]{64}\b"#, []),
        // 13–19 digits, optionally grouped by single spaces or dashes; confirmed by the Luhn check.
        (.creditCard, #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#, []),
    ]

    private static let compiled: [(SecretPattern, NSRegularExpression)] = sources.map { pattern, source, options in
        (pattern, try! NSRegularExpression(pattern: source, options: options))
    }

    private static func matches(_ regex: NSRegularExpression, _ pattern: SecretPattern, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard pattern == .creditCard else { return regex.firstMatch(in: text, range: range) != nil }
        var hit = false
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let r = Range(match.range, in: text) else { return }
            let digits = text[r].compactMap(\.wholeNumberValue)
            if (13...19).contains(digits.count), luhn(digits) {
                hit = true
                stop.pointee = true
            }
        }
        return hit
    }

    /// The Luhn checksum used by payment card numbers.
    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
