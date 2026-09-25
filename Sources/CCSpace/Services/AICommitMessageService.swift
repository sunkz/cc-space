import Foundation
import os

private let aiCommitServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "AICommitMessageService"
)

// MARK: - 错误

/// AI 生成提交信息的错误,文案面向用户。
enum AICommitMessageError: LocalizedError {
    case notConfigured
    case missingAPIKey
    case invalidBaseURL(String)
    case insecureBaseURL(String)
    case http(status: Int, detail: String?)
    case emptyResponse
    case invalidModelList

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 AI 服务，请前往设置页填写 Base URL 与模型名"
        case .missingAPIKey:
            return "尚未填写 AI 服务的 API Key，请前往设置页配置"
        case .invalidBaseURL(let raw):
            return "AI 服务地址无效：\(raw)"
        case .insecureBaseURL(let raw):
            return "AI 服务地址必须使用 HTTPS；仅本机回环地址（如 http://localhost、http://127.0.0.1）允许明文 HTTP：\(raw)"
        case .http(let status, let detail):
            let suffix = detail.map { "：\($0)" } ?? ""
            switch status {
            case 401, 403:
                // 智谱等服务对"模型无权限"也返回 401/403,靠 detail 里的关键词区分,
                // 避免把模型名配置错误误报成 Key 问题。
                if let detail, detail.localizedCaseInsensitiveContains("model") {
                    return "当前账号无权访问该模型，请检查模型名或账号权限\(suffix)"
                }
                return "AI 服务认证失败，请检查 API Key\(suffix)"
            case 429:
                return "AI 服务请求过于频繁，请稍后重试\(suffix)"
            default:
                return "AI 服务返回错误（HTTP \(status)）\(suffix)"
            }
        case .emptyResponse:
            return "AI 未返回有效的提交信息，请重试"
        case .invalidModelList:
            return "未能解析服务返回的模型列表"
        }
    }
}

// MARK: - 服务地址

/// OpenAI 兼容服务端点拼装。
enum AICommitEndpoint {
    /// 把用户填写的 Base URL 规范化为合法根地址:去空白、去结尾斜杠,校验 https
    /// (http 仅放行本机回环,兼容本地 Ollama / LM Studio 等场景),host 为空拒绝。
    static func makeRoot(baseURL: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard trimmed.isEmpty == false,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AICommitMessageError.invalidBaseURL(baseURL)
        }
        let host = (url.host ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard host.isEmpty == false else {
            throw AICommitMessageError.invalidBaseURL(baseURL)
        }
        if scheme == "http", isLoopbackHost(host) == false {
            throw AICommitMessageError.insecureBaseURL(baseURL)
        }
        return url
    }

    /// 本机回环判定:localhost、IPv4 127.0.0.0/8、IPv6 ::1(URL.host 已去方括号,做双重兼容)。
    private static func isLoopbackHost(_ host: String) -> Bool {
        var normalized = host
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        switch normalized {
        case "localhost", "::1", "ip6-localhost":
            return true
        default:
            break
        }
        // IPv4 回环段 127.0.0.0/8:四段点分数字且首段为 127。
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.dropFirst().allSatisfy { octet in
            octet.isEmpty == false && octet.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// OpenAI 兼容 chat completions 端点;用户已填完整端点时原样返回。
    static func make(baseURL: String) throws -> URL {
        let root = try makeRoot(baseURL: baseURL)
        let rootString = root.absoluteString
        if rootString.hasSuffix("/chat/completions") { return root }
        guard let endpoint = URL(string: rootString + "/chat/completions") else {
            throw AICommitMessageError.invalidBaseURL(baseURL)
        }
        return endpoint
    }

    /// 模型列表端点:根地址 + `/models`;用户误填完整 chat 端点时自动剥掉。
    static func makeModelsEndpoint(baseURL: String) throws -> URL {
        var rootString = try makeRoot(baseURL: baseURL).absoluteString
        if rootString.hasSuffix("/chat/completions") {
            rootString = String(rootString.dropLast("/chat/completions".count))
        }
        guard let endpoint = URL(string: rootString + "/models") else {
            throw AICommitMessageError.invalidBaseURL(baseURL)
        }
        return endpoint
    }
}

// MARK: - 模型列表解析

/// 解析 `GET /models` 响应中的模型 ID 列表。
///
/// 兼容两种格式:OpenAI 风格 `{"data":[{"id":…}]}`(智谱 paas/v4 等)
/// 与 Coding 风格 `{"models":[{"slug":…}|{"id":…}]}`。保持服务返回顺序。
enum AIModelListParser {
    private struct OpenAIStyleResponse: Decodable {
        struct Entry: Decodable {
            let id: String?
        }

        let data: [Entry]?
    }

    private struct CodingStyleResponse: Decodable {
        struct Entry: Decodable {
            let id: String?
            let slug: String?
        }

        let models: [Entry]?
    }

    static func parseModelIDs(from data: Data) throws -> [String] {
        if let response = try? JSONDecoder().decode(OpenAIStyleResponse.self, from: data),
           let entries = response.data {
            let ids = entries.compactMap(\.id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            return dedupe(ids)
        }

        if let response = try? JSONDecoder().decode(CodingStyleResponse.self, from: data),
           let entries = response.models {
            let ids = entries.compactMap { $0.slug ?? $0.id }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            return dedupe(ids)
        }

        throw AICommitMessageError.invalidModelList
    }

    private static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Prompt 构建

/// 组装生成提交信息的 Prompt,含 diff 截断与降级策略。
enum AICommitPromptBuilder {
    /// 发送给模型的 diff 总字符预算。
    static let maxTotalPatchCharacters = 40_000
    /// 单个文件 patch 的字符上限,超长截尾。
    static let maxFilePatchCharacters = 6_000
    /// 作为风格参考的最近提交主题数量。
    static let recentCommitSubjectCount = 10

    static func systemPrompt() -> String {
        """
        你是 git 提交信息助手。根据用户提供的改动 diff 生成一条提交信息主题行。要求：
        1. 只输出主题行本身，不要引号、代码块或任何解释。
        2. 单行，不超过 72 个字符。
        3. 概括这次改动最重要的目的，不要罗列文件清单。
        4. 语言与书写风格跟随用户提供的最近提交主题示例；若示例使用「feat:」等前缀，则保持同样的前缀风格。
        """
    }

    static func userPrompt(diffs: [GitDiffEntry], recentCommitSubjects: [String]) -> String {
        var sections: [String] = []

        let subjects = recentCommitSubjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .prefix(recentCommitSubjectCount)
        if subjects.isEmpty == false {
            let bulletList = subjects.map { "- \($0)" }.joined(separator: "\n")
            sections.append("## 最近提交主题（语言与风格参考）\n\(bulletList)")
        }

        let diffSections = makeDiffSections(diffs: diffs)
        if diffSections.isEmpty == false {
            sections.append("## 本次未提交改动\n\(diffSections)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// 把 diff 列表组装为带文件标题的文本段;超总预算时从改动最大的文件开始
    /// 降级为"仅统计",极端情况下硬截断兜底。
    static func makeDiffSections(diffs: [GitDiffEntry]) -> String {
        guard diffs.isEmpty == false else { return "" }

        var sectionTexts = diffs.map { fileSection($0, patchLimit: maxFilePatchCharacters) }
        var totalCharacters = sectionTexts.reduce(0) { $0 + $1.count }

        if totalCharacters > maxTotalPatchCharacters {
            // lockfile/生成物等超大文件信息密度低,优先降级;本来只有统计的文件跳过。
            let orderByMagnitude = diffs.indices.sorted {
                changeMagnitude(diffs[$0]) > changeMagnitude(diffs[$1])
            }
            for index in orderByMagnitude {
                if totalCharacters <= maxTotalPatchCharacters { break }
                let stripped = fileSection(diffs[index], patchLimit: 0)
                totalCharacters -= sectionTexts[index].count - stripped.count
                sectionTexts[index] = stripped
            }
        }

        var output = sectionTexts.joined(separator: "\n\n")
        if output.count > maxTotalPatchCharacters {
            output = String(output.prefix(maxTotalPatchCharacters)) + "\n[diff 过长，已截断]"
        }
        return output
    }

    private static func fileSection(_ entry: GitDiffEntry, patchLimit: Int) -> String {
        let stats: String
        if entry.isBinary {
            stats = "（二进制文件）"
        } else {
            stats = "（+\(entry.insertions) -\(entry.deletions)）"
        }

        let truncatedPatch = patchLimit > 0 ? truncateTail(entry.patch, limit: patchLimit) : ""
        if truncatedPatch.isEmpty {
            return "### \(entry.filePath) \(stats)\n（内容已省略）"
        }
        return "### \(entry.filePath) \(stats)\n```diff\n\(truncatedPatch)\n```"
    }

    private static func truncateTail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[该文件内容过长，已截断]"
    }

    /// 改动量:插删行数之和,二进制文件的 -1 记为 0。
    private static func changeMagnitude(_ entry: GitDiffEntry) -> Int {
        max(0, entry.insertions) + max(0, entry.deletions)
    }
}

// MARK: - 响应解析

/// 解析 OpenAI 兼容 chat completions 响应中的提交信息。
enum AICommitResponseParser {
    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
        }

        let choices: [Choice]?
    }

    /// 提取提交信息:剥离模型可能附带的代码围栏/引号,取首个非空行。
    static func parseCommitMessage(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let raw = response.choices?.first?.message?.content ?? ""
        let message = sanitize(raw)
        guard message.isEmpty == false else {
            throw AICommitMessageError.emptyResponse
        }
        return message
    }

    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 剥掉 ```...``` 围栏(首行可能是 ```swift 之类的语言标注)。
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            if lines.count > 1 {
                lines.removeFirst()
                if let last = lines.last,
                   last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    lines.removeLast()
                }
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 提交栏是单行输入,只取首个非空行。
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            ?? ""
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’` "))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 服务

/// AI 生成提交信息服务协议;extension 提供默认实现,
/// 避免后续新增测试替身时因未实现方法而编译失败(沿用 GitServicing 约定)。
protocol AICommitMessageServicing: Sendable {
    /// 根据工作区改动 diff 生成一条提交信息主题行。
    func generateCommitMessage(
        diffs: [GitDiffEntry],
        recentCommitSubjects: [String]
    ) async throws -> String
}

extension AICommitMessageServicing {
    func generateCommitMessage(
        diffs: [GitDiffEntry],
        recentCommitSubjects: [String]
    ) async throws -> String {
        throw AICommitMessageError.notConfigured
    }
}

/// AI 服务信息能力协议,供设置页拉取模型列表与测试连接;
/// extension 提供默认实现(沿用 GitServicing 约定)。
protocol AIServiceInfoServicing: Sendable {
    /// 拉取服务可用模型 ID 列表(按服务返回顺序)。
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String]
    /// 用一条极短请求验证地址、Key 与模型三者可用;失败抛出带中文原因的错误。
    func testConnection(baseURL: String, modelName: String, apiKey: String) async throws
}

extension AIServiceInfoServicing {
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { [] }
    func testConnection(baseURL: String, modelName: String, apiKey: String) async throws {}
}

/// chat completions 请求体(生成提交信息与测试连接共用)。
private struct ChatCompletionMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionBody: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

/// OpenAI 兼容的提交信息生成服务。
///
/// 生成提交信息时从磁盘读取最新 settings.json(服务地址/模型名/API Key),
/// 因此配置变更即时生效,无需跨窗口同步状态;模型列表/测试连接则使用调用方显式传入的配置。
struct AICommitMessageService: AICommitMessageServicing, AIServiceInfoServicing {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let settingsReader: @Sendable () -> AppSettings?
    private let timeoutInterval: TimeInterval
    private let dataLoader: DataLoader

    init(
        settingsReader: @escaping @Sendable () -> AppSettings?,
        timeoutInterval: TimeInterval = 60,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.settingsReader = settingsReader
        self.timeoutInterval = timeoutInterval
        self.dataLoader = dataLoader
    }

    func generateCommitMessage(
        diffs: [GitDiffEntry],
        recentCommitSubjects: [String]
    ) async throws -> String {
        guard let settings = settingsReader(), let aiSettings = settings.aiSettings else {
            throw AICommitMessageError.notConfigured
        }
        let apiKey = aiSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false else {
            throw AICommitMessageError.missingAPIKey
        }

        let endpoint = try AICommitEndpoint.make(baseURL: aiSettings.baseURL)
        let body = ChatCompletionBody(
            model: aiSettings.modelName,
            messages: [
                ChatCompletionMessage(role: "system", content: AICommitPromptBuilder.systemPrompt()),
                ChatCompletionMessage(
                    role: "user",
                    content: AICommitPromptBuilder.userPrompt(
                        diffs: diffs,
                        recentCommitSubjects: recentCommitSubjects
                    )
                ),
            ],
            temperature: 0.2,
            // GLM-5.x 等"始终思考"模型的推理消耗 completion token,预算太小会导致
            // 正文为空(finish_reason=length);此值只是上限,非思考模型仍只生成短信息。
            maxTokens: 2048,
            stream: false
        )
        let request = try authenticatedJSONRequest(
            url: endpoint, apiKey: apiKey, httpMethod: "POST", body: body
        )

        let (data, response) = try await dataLoader(request)
        guard !Task.isCancelled else { throw CancellationError() }
        try Self.ensureOK(response: response, data: data, event: "generate_commit_message")
        return try AICommitResponseParser.parseCommitMessage(from: data)
    }

    // MARK: - 服务信息(设置页:模型列表 / 测试连接)

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let endpoint = try AICommitEndpoint.makeModelsEndpoint(baseURL: baseURL)
        let request = authenticatedRequest(url: endpoint, apiKey: apiKey, httpMethod: "GET")
        let (data, response) = try await dataLoader(request)
        guard !Task.isCancelled else { throw CancellationError() }
        try Self.ensureOK(response: response, data: data, event: "fetch_models")
        return try AIModelListParser.parseModelIDs(from: data)
    }

    func testConnection(baseURL: String, modelName: String, apiKey: String) async throws {
        let endpoint = try AICommitEndpoint.make(baseURL: baseURL)
        let body = ChatCompletionBody(
            model: modelName,
            messages: [ChatCompletionMessage(role: "user", content: "ping")],
            temperature: 0.2,
            // 连通性探测:HTTP 200 即代表地址/Key/模型三者可用。
            // "始终思考"模型即使正文为空也返回 200,不影响判定。
            maxTokens: 16,
            stream: false
        )
        let request = try authenticatedJSONRequest(
            url: endpoint, apiKey: apiKey, httpMethod: "POST", body: body
        )
        let (data, response) = try await dataLoader(request)
        guard !Task.isCancelled else { throw CancellationError() }
        try Self.ensureOK(response: response, data: data, event: "test_connection")
    }

    /// 构造带鉴权的请求(GET 等无 body 场景)。
    private func authenticatedRequest(url: URL, apiKey: String, httpMethod: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// 用当前已编码的 JSON 体构造带鉴权的请求。
    private func authenticatedJSONRequest<T: Encodable>(
        url: URL,
        apiKey: String,
        httpMethod: String,
        body: T? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    /// 校验 HTTP 响应为 2xx,否则抛出带中文原因的错误。
    private static func ensureOK(response: URLResponse, data: Data, event: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AICommitMessageError.http(status: -1, detail: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = errorMessage(in: data)
            aiCommitServiceLog.error("event=\(event, privacy: .public) status=http_error code=\(httpResponse.statusCode)")
            throw AICommitMessageError.http(status: httpResponse.statusCode, detail: detail)
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let message: String?
        }

        let error: Detail?
    }

    /// 尽力从 OpenAI 兼容错误体中提取 `error.message` 便于定位问题。
    private static func errorMessage(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data),
              let message = body.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              message.isEmpty == false else {
            return nil
        }
        return message
    }
}
