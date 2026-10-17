import Testing
@testable import FunesProtocol

/// spec/domain/memory-processing.md#1-secret-scanner. Samples are assembled at run time, so no
/// credential-shaped literal sits in the repository (and push protection stays quiet).
@Suite struct SecretScannerTests {
    static func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
    static let hex64 = rep("0123456789abcdef", 4)

    struct Sample: Sendable, CustomTestStringConvertible {
        let pattern: SecretPattern
        let text: String
        var testDescription: String { "\(pattern.rawValue): \(text.prefix(40))" }
    }

    static let positives: [Sample] = [
        Sample(pattern: .privateKey, text: "-----BEGIN " + "PRIVATE KEY-----\nMIIEv…"),
        Sample(pattern: .privateKey, text: "here: -----begin rsa " + "private key----- (pasted)"),
        Sample(pattern: .privateKey, text: "-----BEGIN OPENSSH " + "PRIVATE KEY-----"),
        Sample(pattern: .awsAccessKey, text: "key AKIA" + rep("Z", 8) + "12345678 in prod"),
        Sample(pattern: .awsAccessKey, text: "ASIA" + rep("A1", 8)),
        Sample(pattern: .openAIStyleKey, text: "use sk-" + rep("abc", 7) + " for the bot"),
        Sample(pattern: .openAIStyleKey, text: "sk-ant-" + rep("x9", 12)),
        Sample(pattern: .openAIStyleKey, text: "sk-proj-" + rep("Ab_-", 6)),
        Sample(pattern: .githubToken, text: "token ghp_" + rep("a1", 18)),
        Sample(pattern: .githubToken, text: "github_pat_" + rep("B2", 12)),
        Sample(pattern: .jwt, text: "Bearer eyJ" + rep("h", 10) + "." + rep("p", 10) + "." + rep("s", 10)),
        Sample(pattern: .assignedSecret, text: "password: hunter2hunter2"),
        Sample(pattern: .assignedSecret, text: "API_KEY=\"q8w7e6r5t4y3u2\""),
        Sample(pattern: .assignedSecret, text: "client-secret = 'abcdefghijklmnop'"),
        Sample(pattern: .slackToken, text: "xoxb-" + rep("1234-", 3)),
        Sample(pattern: .stripeKey, text: "sk_" + "live_" + rep("a", 24)),
        Sample(pattern: .stripeKey, text: "rk_" + "test_" + rep("Z9", 8)),
        Sample(pattern: .googleAPIKey, text: "AIza" + rep("Sy", 17) + "D"),
        Sample(pattern: .funesOrEKBKey, text: "fns_mcp_v1_" + hex64),
        Sample(pattern: .funesOrEKBKey, text: "ekb_mcpr_v1_" + hex64),
        Sample(pattern: .creditCard, text: "card 4111 1111 1111 1111 exp 04/29"),
        Sample(pattern: .creditCard, text: "5555-5555-5555-4444"),
        Sample(pattern: .creditCard, text: "amex 378282246310005"),
        Sample(pattern: .creditCard, text: "6011111111111117"),
    ]

    static let negatives: [Sample] = [
        Sample(pattern: .privateKey, text: "-----BEGIN PUBLIC KEY-----"),
        Sample(pattern: .awsAccessKey, text: "AKIA" + rep("Z", 15)),
        Sample(pattern: .awsAccessKey, text: "akia" + rep("z", 16)),
        Sample(pattern: .openAIStyleKey, text: "sk-short-key"),
        Sample(pattern: .openAIStyleKey, text: "task-" + rep("a", 30)),
        Sample(pattern: .githubToken, text: "ghp_tooShort"),
        Sample(pattern: .githubToken, text: "github_pat_" + rep("a", 10)),
        Sample(pattern: .jwt, text: "eyJ.short.parts"),
        Sample(pattern: .assignedSecret, text: "password: short"),
        Sample(pattern: .assignedSecret, text: "I reset my password yesterday and it was annoying"),
        Sample(pattern: .slackToken, text: "xoxz-1234567890"),
        Sample(pattern: .stripeKey, text: "sk_" + "live_short"),
        Sample(pattern: .googleAPIKey, text: "AIza" + rep("S", 20)),
        Sample(pattern: .funesOrEKBKey, text: "fns_mcp_v1_" + String(hex64.dropLast())),
        Sample(pattern: .funesOrEKBKey, text: "fns_mcp_v2_" + hex64),
        Sample(pattern: .creditCard, text: "4111 1111 1111 1112"),
        Sample(pattern: .creditCard, text: "411111111111"),
        Sample(pattern: .creditCard, text: rep("4111", 5) + "1"),
    ]

    @Test(arguments: positives) func detects(_ sample: Sample) {
        #expect(SecretScanner.scan(sample.text).contains(sample.pattern))
    }

    @Test(arguments: negatives) func ignores(_ sample: Sample) {
        #expect(!SecretScanner.scan(sample.text).contains(sample.pattern))
    }

    @Test func reportsTypesOnceInOrder() {
        let text = "sk-" + Self.rep("a", 24) + " and 4111111111111111 and sk-" + Self.rep("b", 24)
        #expect(SecretScanner.scan([text, "-----BEGIN EC PRIVATE KEY-----"]) == [.privateKey, .openAIStyleKey, .creditCard])
        #expect(SecretScanner.scan("") == [])
        #expect(SecretScanner.containsSecret("plain", "AKIA" + Self.rep("Q", 16)))
    }

    @Test func luhn() {
        #expect(SecretScanner.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        #expect(!SecretScanner.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
        #expect(SecretScanner.luhn([7, 9, 9, 2, 7, 3, 9, 8, 7, 1, 3]))
    }

    /// Realistic memories that must never be blocked (a false positive is a scanner bug).
    static let ordinary: [String] = [
        "I prefer concise answers: lead with the answer, then at most three short paragraphs.",
        "Use pnpm for packages and Vitest for tests in every TypeScript repo.",
        "My passport expires in March 2031; remind me to renew it six months before.",
        "Call me on +54 9 11 5555 1234 only for urgent things.",
        "Our office is at 1600 Example Avenue, Suite 400, Springfield 12345.",
        "The sailing club invoice INV-2026-0042 for 180 EUR is due on 2026-11-01.",
        "I reset my password every 90 days using the password manager.",
        "The API key for the staging server lives in 1Password, never in the repo.",
        "I'm allergic to peanuts and tree nuts; carry an EpiPen.",
        "Commit messages: imperative mood, max 72 characters in the subject line.",
        "My sister's birthday is 14/02/1990 and she likes orchids.",
        "Order 1234567890 from the bike shop arrives next Tuesday.",
        "Kubernetes cluster sk-prod runs in eu-west-1; deploys go through Argo.",
        "Use the task-runner script (scripts/task-runner.sh) instead of make.",
        "I take 20 mg of medication every morning at 8:00.",
        "Salary is paid on the 25th; rent of 1,250 USD leaves on the 1st.",
        "Our Wi-Fi network is called FunesHome; guests use FunesGuest.",
        "For JWT auth in the API, tokens expire after 15 minutes and refresh after 7 days.",
        "Tracking number 1Z999AA10123456784 for the parcel from Lisbon.",
        "Version 2.14.1 of the library broke the build on 2026-10-16 at 10:42.",
    ]

    @Test func ordinaryMemoriesPass() {
        for text in Self.ordinary {
            #expect(SecretScanner.scan(text).isEmpty, "\(text)")
        }
    }
}
