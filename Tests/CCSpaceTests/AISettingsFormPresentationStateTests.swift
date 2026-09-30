import XCTest
@testable import CCSpace

final class AISettingsFormPresentationStateTests: XCTestCase {
    private func storedAI(
        baseURL: String = "https://api.example.com/v1",
        modelName: String = "glm-5.3-flash",
        apiKey: String = "sk-secret-123"
    ) -> AppSettings.AISettings {
        AppSettings.AISettings(baseURL: baseURL, modelName: modelName, apiKey: apiKey)
    }

    func test_matchesStoredConfigurationMeansNotDirty() {
        let state = AISettingsFormPresentationState(
            baseURL: "https://api.example.com/v1",
            modelName: "glm-5.3-flash",
            apiKey: "sk-secret-123",
            stored: storedAI()
        )

        XCTAssertFalse(state.isDirty)
    }

    func test_trimmingWhitespaceAroundInputsMeansNotDirty() {
        // 输入框两端多敲的空格保存时会被 trim 掉,不算修改。
        let state = AISettingsFormPresentationState(
            baseURL: " https://api.example.com/v1 ",
            modelName: " glm-5.3-flash ",
            apiKey: " sk-secret-123 ",
            stored: storedAI()
        )

        XCTAssertFalse(state.isDirty)
    }

    func test_anyFieldChangeMeansDirty() {
        let baseURLChanged = AISettingsFormPresentationState(
            baseURL: "https://other.example.com/v1",
            modelName: "glm-5.3-flash",
            apiKey: "sk-secret-123",
            stored: storedAI()
        )
        let modelNameChanged = AISettingsFormPresentationState(
            baseURL: "https://api.example.com/v1",
            modelName: "gpt-test",
            apiKey: "sk-secret-123",
            stored: storedAI()
        )
        let apiKeyChanged = AISettingsFormPresentationState(
            baseURL: "https://api.example.com/v1",
            modelName: "glm-5.3-flash",
            apiKey: "sk-other",
            stored: storedAI()
        )

        XCTAssertTrue(baseURLChanged.isDirty)
        XCTAssertTrue(modelNameChanged.isDirty)
        XCTAssertTrue(apiKeyChanged.isDirty)
    }

    func test_clearingBothBaseURLAndModelNameIsADirtyChange() {
        // 清空两者 = 关闭 AI 功能,属于需要用户确认落盘的修改。
        let state = AISettingsFormPresentationState(
            baseURL: "",
            modelName: "",
            apiKey: "",
            stored: storedAI()
        )

        XCTAssertTrue(state.isDirty)
    }

    func test_neverConfiguredFormIsEmptyIsNotDirty() {
        let state = AISettingsFormPresentationState(
            baseURL: "",
            modelName: "",
            apiKey: "",
            stored: nil
        )

        XCTAssertFalse(state.isDirty)
    }

    func test_neverConfiguredFormWithAnyInputIsDirty() {
        let keyOnlyState = AISettingsFormPresentationState(
            baseURL: "",
            modelName: "",
            apiKey: "sk-new",
            stored: nil
        )

        XCTAssertTrue(keyOnlyState.isDirty)
    }

    // MARK: - 动作前置校验

    func test_actionValidationRequiresBaseURL() {
        XCTAssertEqual(
            AISettingsFormPresentationState.actionValidationError(
                baseURL: "   ",
                modelName: "glm",
                requireModel: true
            ),
            "请先填写 Base URL"
        )
    }

    func test_actionValidationRequiresModelOnlyWhenAsked() {
        XCTAssertEqual(
            AISettingsFormPresentationState.actionValidationError(
                baseURL: "https://api.example.com/v1",
                modelName: "",
                requireModel: true
            ),
            "请先填写模型名"
        )
        XCTAssertNil(
            AISettingsFormPresentationState.actionValidationError(
                baseURL: "https://api.example.com/v1",
                modelName: "",
                requireModel: false
            ),
            "拉模型列表允许模型名暂空(先拉列表再选)"
        )
    }

    func test_actionValidationNeverRequiresAPIKey() {
        // 本地服务(Ollama/LM Studio)不需要密钥:缺 Key 不得拦截,
        // 由服务端 401 原样反馈。
        XCTAssertNil(
            AISettingsFormPresentationState.actionValidationError(
                baseURL: "http://localhost:11434/v1",
                modelName: "llama3",
                requireModel: true
            )
        )
        XCTAssertNil(
            AISettingsFormPresentationState.actionValidationError(
                baseURL: "http://localhost:11434/v1",
                modelName: "llama3",
                requireModel: false
            )
        )
    }
}
