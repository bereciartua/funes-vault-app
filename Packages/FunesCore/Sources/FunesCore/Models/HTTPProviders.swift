import Darwin
import Foundation
import FunesProtocol

/// A local server or cloud endpoint the user added (Settings ▸ AI Models ▸ Providers). Stored in
/// user defaults without its key; the key lives in the Keychain.
public struct ProviderEndpoint: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case openAICompatible = "openai_compatible", anthropic }

    public var id: ProviderID
    public var kind: Kind
    public var baseURL: URL
    /// The user marked it as cloud. A non-local host is cloud whatever the user said.
    public var markedCloud: Bool

    public init(id: ProviderID, kind: Kind, baseURL: URL, markedCloud: Bool = false) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.markedCloud = markedCloud
    }

    public static func openAI() -> ProviderEndpoint {
        ProviderEndpoint(id: "openai", kind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!)
    }
    public static func anthropic() -> ProviderEndpoint {
        ProviderEndpoint(id: "anthropic", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com/v1")!)
    }
    public static func ollama() -> ProviderEndpoint {
        ProviderEndpoint(id: "ollama", kind: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:11434/v1")!)
    }
    public static func lmStudio() -> ProviderEndpoint {
        ProviderEndpoint(id: "lmstudio", kind: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:1234/v1")!)
    }

    /// Local server when the host is loopback or a private address and the user didn't mark it
    /// as cloud; cloud otherwise (model providers §2).
    public func locality(resolve: @Sendable (String) -> [String] = LocalityDetector.resolve) -> Locality {
        guard !markedCloud, let host = baseURL.host() else { return .cloud }
        return LocalityDetector.isLocal(host: host, resolve: resolve) ? .localServer : .cloud
    }
}

/// "Local" means the endpoint's host is loopback or a private address (model providers §2).
public enum LocalityDetector {
    public static func isLocal(host: String, resolve: @Sendable (String) -> [String] = resolve) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if isLiteralAddress(h) { return isLocalAddress(h) }
        let addresses = resolve(h)
        return !addresses.isEmpty && addresses.allSatisfy(isLocalAddress)
    }

    static func isLiteralAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// Loopback, RFC 1918, link-local, and IPv6 loopback, unique-local and link-local.
    public static func isLocalAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }       // ::1
            if b[0] & 0xFE == 0xFC { return true }                                    // fc00::/7
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }                    // fe80::/10
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {  // ::ffff:a.b.c.d
                return isLocalAddress("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
        }
        return false
    }

    /// The host's addresses via getaddrinfo.
    public static let resolve: @Sendable (String) -> [String] = { host in
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}

/// Shared HTTP plumbing: TLS for cloud endpoints, status mapping, JSON bodies.
struct HTTPClient: Sendable {
    let session: URLSession
    let endpoint: ProviderEndpoint
    let locality: Locality

    init(endpoint: ProviderEndpoint, session: URLSession, locality: Locality) throws {
        // Plain HTTP only for local servers (model providers §5.5).
        if locality == .cloud, endpoint.baseURL.scheme?.lowercased() != "https" { throw ProviderError.insecureEndpoint }
        self.session = session
        self.endpoint = endpoint
        self.locality = locality
    }

    func send(_ path: String, method: String = "POST", headers: [String: String], body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.baseURL.appending(path: path))
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONWriter.data(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw ProviderError.unauthorized
        case 429:
            throw ProviderError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init))
        default: throw ProviderError.server(status: http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidOutput }
        return object
    }

    static func decode<T: Decodable>(_ text: String, as: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw ProviderError.invalidOutput
        }
    }
}

/// OpenAI, Ollama, LM Studio, Gemini, OpenRouter and custom endpoints: chat completions with
/// `response_format: json_schema` (strict), and the model list. Embeddings are
/// `OpenAICompatibleEmbedder`.
public struct OpenAICompatibleClient: GenerationProvider {
    public let id: ProviderID
    public let locality: Locality
    public let modelID: String
    let http: HTTPClient
    let apiKey: String?

    public init(endpoint: ProviderEndpoint, model: String, apiKey: String?, session: URLSession = .shared,
                locality: Locality? = nil) throws {
        let locality = locality ?? endpoint.locality()
        id = endpoint.id
        self.locality = locality
        modelID = model
        self.apiKey = apiKey
        http = try HTTPClient(endpoint: endpoint, session: session, locality: locality)
    }

    var headers: [String: String] { apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:] }

    public func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": request.maxOutputTokens,
            "messages": [["role": "system", "content": request.instructions], ["role": "user", "content": request.prompt]],
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": request.schemaName, "strict": true, "schema": request.schema.wire]],
        ]
        let response = try await http.send("chat/completions", headers: headers, body: body)
        guard let choice = (response["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw ProviderError.invalidOutput }
        if message["refusal"] is String { throw ProviderError.refused }
        guard let content = message["content"] as? String else { throw ProviderError.invalidOutput }
        let usage = response["usage"] as? [String: Any]
        return (try HTTPClient.decode(content, as: T.self),
                ProviderUsage(requests: 1, inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
                              outputTokens: usage?["completion_tokens"] as? Int ?? 0))
    }

    /// `GET /models`: the provider's model ids, sorted.
    public func listModels() async throws -> [String] {
        let response = try await http.send("models", method: "GET", headers: headers, body: nil)
        return ((response["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

/// The same endpoints' `/v1/embeddings` (ADR-0023, model providers §7): a provider model's vectors
/// for the second index. Models that expect role prefixes get them here (`EmbeddingCatalog`).
/// Call it only through `ModelRouter.embed`, which applies the guardrails.
public struct OpenAICompatibleEmbedder: EmbeddingProvider {
    public let id: ProviderID
    public let locality: Locality
    public let model: EmbeddingModelInfo
    /// The provider's model name, e.g. `text-embedding-3-small` or `qwen3-embedding:0.6b`.
    public let modelName: String
    public let queryPrefix: String
    public let documentPrefix: String
    let http: HTTPClient
    let apiKey: String?

    /// `info` nil: the catalog's dimensions and thresholds for a known model, or an uncalibrated
    /// model of `dimensions` (from `probeDimensions`).
    public init(endpoint: ProviderEndpoint, model: String, info: EmbeddingModelInfo? = nil, dimensions: Int? = nil,
                apiKey: String?, session: URLSession = .shared, locality: Locality? = nil) throws {
        let locality = locality ?? endpoint.locality()
        let known = EmbeddingCatalog.lookup(model)
        let id = Self.modelID(provider: endpoint.id, model: model)
        guard let info = info ?? known.flatMap({ $0.info(id: id) })
            ?? (dimensions ?? known?.dimensions).map({ EmbeddingModelInfo.uncalibrated(id: id, dimensions: $0) }) else {
            throw ProviderError.unavailable
        }
        self.id = endpoint.id
        self.locality = locality
        self.model = info
        modelName = model
        queryPrefix = known?.queryPrefix ?? ""
        documentPrefix = known?.documentPrefix ?? ""
        self.apiKey = apiKey
        http = try HTTPClient(endpoint: endpoint, session: session, locality: locality)
    }

    /// The id stored with its vectors: `<provider id>/<model name>`.
    public static func modelID(provider: ProviderID, model: String) -> String { "\(provider.rawValue)/\(model)" }

    var headers: [String: String] { apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:] }

    public func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        try await embedCounting(texts, as: role).0
    }

    /// The vectors, in input order, and the tokens the provider reports.
    public func embedCounting(_ texts: [String], as role: EmbeddingRole) async throws -> ([[Float]], ProviderUsage) {
        guard !texts.isEmpty else { return ([], ProviderUsage()) }
        let prefix = role == .query ? queryPrefix : documentPrefix
        let body: [String: Any] = ["model": modelName, "input": texts.map { prefix + $0 }, "encoding_format": "float"]
        let response = try await http.send("embeddings", headers: headers, body: body)
        guard let data = response["data"] as? [[String: Any]], data.count == texts.count else { throw ProviderError.invalidOutput }
        let ordered = data.enumerated().sorted { ($0.element["index"] as? Int ?? $0.offset) < ($1.element["index"] as? Int ?? $1.offset) }
        let vectors = try ordered.map { item -> [Float] in
            guard let values = item.element["embedding"] as? [NSNumber], !values.isEmpty else { throw ProviderError.invalidOutput }
            return values.map(\.floatValue)
        }
        guard Set(vectors.map(\.count)).count == 1 else { throw ProviderError.invalidOutput }
        let usage = response["usage"] as? [String: Any]
        return (vectors, ProviderUsage(requests: 1, inputTokens: usage?["prompt_tokens"] as? Int ?? 0))
    }
}

/// Claude through the Messages API, with structured output via `output_config.format`
/// (`json_schema`). Generation only.
public struct AnthropicClient: GenerationProvider {
    public static let apiVersion = "2023-06-01"
    /// The suggested default for classification: a small, fast model is enough.
    public static let suggestedModel = "claude-haiku-5-5"

    public let id: ProviderID
    public let locality: Locality
    public let modelID: String
    let http: HTTPClient
    let apiKey: String

    public init(endpoint: ProviderEndpoint = .anthropic(), model: String = AnthropicClient.suggestedModel, apiKey: String,
                session: URLSession = .shared) throws {
        id = endpoint.id
        locality = endpoint.locality()
        modelID = model
        self.apiKey = apiKey
        http = try HTTPClient(endpoint: endpoint, session: session, locality: locality)
    }

    var headers: [String: String] { ["x-api-key": apiKey, "anthropic-version": Self.apiVersion] }

    public func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": request.maxOutputTokens,
            "system": request.instructions,
            "messages": [["role": "user", "content": request.prompt]],
            "output_config": ["format": ["type": "json_schema", "schema": request.schema.wire]],
        ]
        let response = try await http.send("messages", headers: headers, body: body)
        if (response["stop_reason"] as? String) == "refusal" { throw ProviderError.refused }
        if (response["stop_reason"] as? String) == "max_tokens" { throw ProviderError.invalidOutput }
        let blocks = (response["content"] as? [[String: Any]]) ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ProviderError.invalidOutput
        }
        let usage = response["usage"] as? [String: Any]
        return (try HTTPClient.decode(text, as: T.self),
                ProviderUsage(requests: 1, inputTokens: usage?["input_tokens"] as? Int ?? 0,
                              outputTokens: usage?["output_tokens"] as? Int ?? 0))
    }

    /// `GET /models`: Claude model ids.
    public func listModels() async throws -> [String] {
        let response = try await http.send("models", method: "GET", headers: headers, body: nil)
        return ((response["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}
