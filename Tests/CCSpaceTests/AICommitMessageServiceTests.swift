import XCTest
@testable import CCSpace

/// 捕获 dataLoader 收到的请求(记忆约定:用 @unchecked Sendable 盒跨闭包传递)。
private final class RequestRecorder: @unchecked Sendable {
    var request: URLRequest?
}

final class AICommitMessageServiceTests: XCTestCase {
    private let sampleDiffs = [
        GitDiffEntry(
            filePath: "Sources/Foo.swift",
            insertions: 12,
            deletions: 3,
            patch: "@@ -1,2 +1,3 @@\n+let x = 1"
        )
    ]

    private func makeSettings(aiSettings: AppSettings.AISettings?) -> AppSettings {
        var settings = AppSettings(workplaceRootPath: "/tmp/workplaces")
        settings.aiSettings = aiSettings
        return settings
    }

    private func makeAISettings(
        baseURL: String = "https://api.example.com/v1",
        modelName: String = "gpt-test",
        apiKey: String = "sk-test"
    ) -> AppSettings.AISettings {
        AppSettings.AISettings(baseURL: baseURL, modelName: modelName, apiKey: apiKey)
    }

    private func makeSuccessData() -> Data {
        let payload = [
            "choices": [
                ["message": ["content": "feat: 添加 AI 提交信息"]]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeService(
        settings: AppSettings?,
        recorder: RequestRecorder? = nil,
        responder: @escaping @Sendable () -> (Data, Int) = { (Data(), 200) }
    ) -> AICommitMessageService {
        AICommitMessageService(
            settingsReader: { settings },
            dataLoader: { request in
                recorder?.request = request
                let (data, statusCode) = responder()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        )
    }

    // MARK: - 前置校验

    func test_notConfiguredWhenSettingsMissingAISettings() async {
        let service = makeService(settings: makeSettings(aiSettings: nil))

        do {
            _ = try await service.generateCommitMessage(
                diffs: sampleDiffs,
                recentCommitSubjects: []
            )
            XCTFail("Expected notConfigured error")
        } catch {
            guard case AICommitMessageError.notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        }
    }

    func test_missingAPIKeyWhenSavedAPIKeyEmpty() async {
        let service = makeService(
            settings: makeSettings(aiSettings: makeAISettings(apiKey: ""))
        )

        do {
            _ = try await service.generateCommitMessage(
                diffs: sampleDiffs,
                recentCommitSubjects: []
            )
            XCTFail("Expected missingAPIKey error")
        } catch {
            guard case AICommitMessageError.missingAPIKey = error else {
                return XCTFail("Expected missingAPIKey, got \(error)")
            }
        }
    }

    func test_invalidBaseURLRejected() async {
        let service = makeService(
            settings: makeSettings(aiSettings: makeAISettings(baseURL: "ftp://api.example.com"))
        )

        do {
            _ = try await service.generateCommitMessage(
                diffs: sampleDiffs,
                recentCommitSubjects: []
            )
            XCTFail("Expected invalidBaseURL error")
        } catch {
            guard case AICommitMessageError.invalidBaseURL = error else {
                return XCTFail("Expected invalidBaseURL, got \(error)")
            }
        }
    }

    // MARK: - 请求构造

    func test_requestTargetsChatCompletionsWithBearerTokenAndPrompt() async throws {
        let recorder = RequestRecorder()
        let successData = makeSuccessData()
        let service = makeService(
            settings: makeSettings(aiSettings: makeAISettings(
                baseURL: "https://api.example.com/v1/",
                modelName: "gpt-test",
                apiKey: "sk-test"
            )),
            recorder: recorder,
            responder: { (successData, 200) }
        )

        let message = try await service.generateCommitMessage(
            diffs: sampleDiffs,
            recentCommitSubjects: ["feat: 历史提交"]
        )

        XCTAssertEqual(message, "feat: 添加 AI 提交信息")
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.timeoutInterval, 60, accuracy: 0.1)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        let userContent = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(userContent.contains("Sources/Foo.swift"))
        XCTAssertTrue(userContent.contains("feat: 历史提交"))
    }

    // MARK: - 错误映射

    func test_http401MapsToAuthenticationFailureWithAPIDetail() async {
        let errorBody = #"{"error":{"message":"bad key"}}"#
        let service = makeService(
            settings: makeSettings(aiSettings: makeAISettings()),
            responder: { (Data(errorBody.utf8), 401) }
        )

        do {
            _ = try await service.generateCommitMessage(
                diffs: sampleDiffs,
                recentCommitSubjects: []
            )
            XCTFail("Expected http error")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("认证失败"), "实际文案：\(description)")
            XCTAssertTrue(description.contains("bad key"), "实际文案：\(description)")
        }
    }

    func test_http429MapsToRateLimitMessage() async {
        let service = makeService(
            settings: makeSettings(aiSettings: makeAISettings()),
            responder: { (Data(), 429) }
        )

        do {
            _ = try await service.generateCommitMessage(
                diffs: sampleDiffs,
                recentCommitSubjects: []
            )
            XCTFail("Expected http error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("请求过于频繁"), "实际文案：\(error.localizedDescription)")
        }
    }

    // MARK: - 端点拼装

    func test_endpointMakeAppendsChatCompletionsPath() throws {
        let endpoint = try AICommitEndpoint.make(baseURL: "https://api.example.com/v1/")
        XCTAssertEqual(endpoint.absoluteString, "https://api.example.com/v1/chat/completions")
    }

    func test_endpointMakeKeepsExplicitChatCompletionsEndpoint() throws {
        let endpoint = try AICommitEndpoint.make(
            baseURL: "https://gateway.example.com/openai/chat/completions"
        )
        XCTAssertEqual(endpoint.absoluteString, "https://gateway.example.com/openai/chat/completions")
    }

    func test_endpointMakeRejectsNonHTTPSchemeAndGarbage() {
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "ftp://api.example.com"))
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "不是地址"))
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "   "))
    }

    /// Base URL 含 query/fragment 时,拼接 /chat/completions 会得到错误端点,必须拒绝。
    func test_endpointMakeRejectsBaseURLWithQueryOrFragment() {
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "https://api.example.com/v1?key=1")) { error in
            guard case AICommitMessageError.invalidBaseURL = error else {
                return XCTFail("应为 invalidBaseURL,实际:\(error)")
            }
        }
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "https://api.example.com/v1#frag"))
        XCTAssertThrowsError(try AICommitEndpoint.makeModelsEndpoint(baseURL: "https://api.example.com/v1?key=1"))
    }

    /// 明文 http 仅放行本机回环;远端主机一律拒绝(HTTPS-only)。
    func test_endpointMakeRejectsPlainHTTPForNonLoopbackHosts() {
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "http://api.example.com/v1")) { error in
            guard case AICommitMessageError.insecureBaseURL = error else {
                return XCTFail("应为 insecureBaseURL,实际:\(error)")
            }
        }
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "http://8.8.8.8"))
        // 形似 127 但不在回环段:同样拒绝。
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "http://127.example.com"))
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "http://notlocalhost:11434"))
    }

    /// 本地 Ollama / LM Studio 是常见场景:http://localhost、127.0.0.1、[::1] 应放行。
    func test_endpointMakeAllowsLoopbackHTTP() throws {
        XCTAssertEqual(
            try AICommitEndpoint.make(baseURL: "http://localhost:11434/v1").absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
        let v1Host = try AICommitEndpoint.make(baseURL: "http://127.0.0.1:1234/v1")
        XCTAssertEqual(v1Host.host, "127.0.0.1")
        XCTAssertEqual(v1Host.path, "/v1/chat/completions")
        let ipv6 = try AICommitEndpoint.make(baseURL: "http://[::1]:11434")
        XCTAssertEqual(ipv6.host, "::1")
        XCTAssertTrue(ipv6.absoluteString.hasSuffix("/chat/completions"))
    }

    /// host 为空的地址无法请求,一律拒绝。
    func test_endpointMakeRejectsEmptyHost() {
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "https://")) { error in
            guard case AICommitMessageError.invalidBaseURL = error else {
                return XCTFail("应为 invalidBaseURL,实际:\(error)")
            }
        }
        XCTAssertThrowsError(try AICommitEndpoint.make(baseURL: "http://"))
    }

    /// https 场景不受 HTTP 限制影响(回归哨兵)。
    func test_endpointMakeAcceptsHTTPS() throws {
        XCTAssertEqual(
            try AICommitEndpoint.make(baseURL: "https://api.example.com/v1").host,
            "api.example.com"
        )
    }

    func test_endpointMakeModelsAppendsModelsPath() throws {
        let endpoint = try AICommitEndpoint.makeModelsEndpoint(baseURL: "https://api.example.com/v1/")
        XCTAssertEqual(endpoint.absoluteString, "https://api.example.com/v1/models")
    }

    func test_endpointMakeModelsStripsExplicitChatCompletionsSuffix() throws {
        let endpoint = try AICommitEndpoint.makeModelsEndpoint(
            baseURL: "https://api.example.com/v1/chat/completions"
        )
        XCTAssertEqual(endpoint.absoluteString, "https://api.example.com/v1/models")
    }

    // MARK: - 模型列表

    func test_fetchModelsSendsGETAndParsesList() async throws {
        let recorder = RequestRecorder()
        let listData = #"{"data":[{"id":"glm-5.3"},{"id":"glm-5.3-flash"}]}"#
        let service = makeService(
            settings: makeSettings(
                aiSettings: .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test")
            ),
            recorder: recorder,
            responder: { (Data(listData.utf8), 200) }
        )

        let models = try await service.fetchModels(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-test"
        )

        XCTAssertEqual(models, ["glm-5.3", "glm-5.3-flash"])
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func test_fetchModelsHTTPErrorPropagatesDetail() async {
        let errorBody = #"{"error":{"message":"bad key"}}"#
        let service = makeService(
            settings: makeSettings(
                aiSettings: .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test")
            ),
            responder: { (Data(errorBody.utf8), 401) }
        )

        do {
            _ = try await service.fetchModels(baseURL: "https://api.example.com/v1", apiKey: "sk-test")
            XCTFail("Expected http error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("认证失败"), "实际文案：\(error.localizedDescription)")
        }
    }

    // MARK: - 测试连接

    func test_testConnectionSucceedsOnHTTP200() async throws {
        let recorder = RequestRecorder()
        let service = makeService(
            settings: makeSettings(
                aiSettings: .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test")
            ),
            recorder: recorder,
            responder: { (Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8), 200) }
        )

        try await service.testConnection(
            baseURL: "https://api.example.com/v1",
            modelName: "gpt-test",
            apiKey: "sk-test"
        )

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["max_tokens"] as? Int, 16)
    }

    func test_testConnectionModelPermissionErrorMentionsModel() async {
        let errorBody = #"{"error":{"code":"model_access_denied","message":"No permission to access model: glm-5.3-flash"}}"#
        let service = makeService(
            settings: makeSettings(
                aiSettings: .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test")
            ),
            responder: { (Data(errorBody.utf8), 403) }
        )

        do {
            try await service.testConnection(
                baseURL: "https://api.example.com/v1",
                modelName: "glm-5.3-flash",
                apiKey: "sk-test"
            )
            XCTFail("Expected http error")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("无权访问该模型"), "实际文案：\(description)")
            XCTAssertFalse(description.contains("认证失败"), "不应误报为 Key 问题：\(description)")
        }
    }
}
