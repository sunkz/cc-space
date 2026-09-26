import SwiftUI

/// 设置页「AI 服务」区块:配置 OpenAI 兼容服务,供提交信息生成等 AI 功能共用。
///
/// 服务地址与模型名保存在 settings.json;API Key 优先存入钥匙串,
/// 钥匙串不可用时降级为明文保存在 settings.json(界面据此展示明文落盘警示)。
/// 支持从服务拉取模型列表选择、测试连接。
struct AISettingsSection: View {
    @ObservedObject private var settingsStore: SettingsStore
    private let aiService: AIServiceInfoServicing

    @State private var baseURLText: String
    @State private var modelNameText: String
    /// API Key 输入;初始化时回显已保存值(SecureField 按字符显示掩码),所见即所存。
    @State private var apiKeyText: String
    @State private var feedback: CCSpaceFeedback?
    @State private var isTestingConnection = false
    @State private var isFetchingModels = false
    @State private var showsModelPicker = false
    @State private var fetchedModels: [String] = []
    /// 网络请求任务句柄:视图消失(含切换设置页签)时取消,避免迟到回调写已离场视图的状态。
    @State private var fetchModelsTask: Task<Void, Never>?
    @State private var testConnectionTask: Task<Void, Never>?

    init(settingsStore: SettingsStore, aiService: AIServiceInfoServicing) {
        self.settingsStore = settingsStore
        self.aiService = aiService
        let aiSettings = settingsStore.settings.aiSettings
        _baseURLText = State(initialValue: aiSettings?.baseURL ?? "")
        _modelNameText = State(initialValue: aiSettings?.modelName ?? "")
        _apiKeyText = State(initialValue: aiSettings?.apiKey ?? "")
    }

    private var trimmedAPIKey: String {
        apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            configPanel

            if let shownFeedback = feedback {
                CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { self.feedback = nil })
                    .ccspaceAutoDismissFeedback($feedback)
            }
        }
        .ccspacePanel(
            background: .clear,
            cornerRadius: 12,
            padding: 12,
            borderOpacity: 0.03
        )
        .onDisappear {
            // 视图从视图树移除(设置页整体关闭)时取消在途请求并复位进行中状态。
            // 页签切换不再触发本回调:两页签常驻视图树以保留未保存输入。
            fetchModelsTask?.cancel()
            fetchModelsTask = nil
            testConnectionTask?.cancel()
            testConnectionTask = nil
            isFetchingModels = false
            isTestingConnection = false
        }
    }

    // MARK: - 头部

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 服务")
                    .font(.title3.weight(.semibold))
                Text("OpenAI 兼容服务，供各 AI 功能共用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            testConnectionButton
            saveButton
        }
    }

    private var testConnectionButton: some View {
        Button {
            testConnection()
        } label: {
            if isTestingConnection {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("测试连接")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isTestingConnection)
        .ccspaceQuickHelp("发一条测试请求验证当前配置")
    }

    private var saveButton: some View {
        Button("保存") { save() }
            .ccspacePrimaryActionButton()
    }

    // MARK: - 配置表单

    /// API Key 输入框(掩码显示)。
    private var apiKeyField: some View {
        SecureField("sk-…", text: $apiKeyText)
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
    }

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldRow(label: "Base URL") {
                TextField("https://open.bigmodel.cn/api/paas/v4", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .center, spacing: 10) {
                Text("API Key")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                apiKeyField

                Text("模型名")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)

                TextField("glm-5.3-flash", text: $modelNameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, maxWidth: 140)

                fetchModelsButton
            }

            // 钥匙串不可用时的明文降级是持久状态,提示常驻展示直到恢复;
            // apiKeyStoredInKeychain 由 SettingsStore 维护,这里只读。
            if settingsStore.apiKeyStoredInKeychain == false {
                Text("钥匙串不可用，API Key 正以明文保存在 settings.json 中")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .ccspaceInsetPanel(
            background: Color.primary.opacity(0.02),
            cornerRadius: 12,
            padding: 10,
            borderOpacity: 0.04
        )
    }

    private var fetchModelsButton: some View {
        Button {
            fetchModels()
        } label: {
            if isFetchingModels {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chevron.up.chevron.down")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isFetchingModels)
        .ccspaceQuickHelp("从服务获取可用模型列表")
        .ccspacePopover(isPresented: $showsModelPicker, arrowEdge: .bottom) {
            modelPickerPopover
        }
    }

    @ViewBuilder
    private var modelPickerPopover: some View {
        if fetchedModels.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
                Text("服务未返回模型")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 260)
        } else {
            ModelPickerPopoverContent(
                models: fetchedModels,
                currentModel: trimmedModelName
            ) { model in
                modelNameText = model
                showsModelPicker = false
            }
            .frame(width: 260)
        }
    }

    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            content()
        }
    }

    private var trimmedBaseURL: String {
        baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModelName: String {
        modelNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 动作

    /// 保存配置:Base URL 与模型名需同时填写(清除两者则视为关闭 AI 功能)。
    /// Key 输入框回显已保存值,保存时所见即所存。
    private func save() {
        let baseURL = trimmedBaseURL
        let modelName = trimmedModelName

        do {
            if baseURL.isEmpty && modelName.isEmpty {
                try settingsStore.updateAISettings(nil)
            } else {
                guard baseURL.isEmpty == false, modelName.isEmpty == false else {
                    feedback = CCSpaceFeedback(
                        style: .error,
                        message: "Base URL 与模型名需同时填写；如需关闭 AI 功能，请将两者都清空后保存"
                    )
                    return
                }
                // 复用服务的端点规则做校验,保证设置页与实际调用口径一致。
                _ = try AICommitEndpoint.make(baseURL: baseURL)
                try settingsStore.updateAISettings(
                    .init(baseURL: baseURL, modelName: modelName, apiKey: trimmedAPIKey)
                )
            }

            feedback = CCSpaceFeedbackFactory.actionSuccess("AI 设置已保存")
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "保存 AI 设置", error: error)
        }
    }

    /// 从服务拉取可用模型列表;成功后弹出选择浮层。
    private func fetchModels() {
        guard validateInputsForAction(requireModel: false) else { return }
        isFetchingModels = true
        let baseURL = trimmedBaseURL
        let apiKey = trimmedAPIKey
        fetchModelsTask?.cancel()
        fetchModelsTask = Task {
            do {
                let models = try await aiService.fetchModels(baseURL: baseURL, apiKey: apiKey)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    fetchedModels = models
                    isFetchingModels = false
                    if models.isEmpty {
                        feedback = CCSpaceFeedback(style: .info, message: "服务未返回任何模型")
                    } else {
                        showsModelPicker = true
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isFetchingModels = false
                    feedback = CCSpaceFeedbackFactory.actionError(action: "获取模型列表", error: error)
                }
            }
        }
    }

    /// 用当前填写的地址、Key 与模型发一条极短请求验证三者可用。
    private func testConnection() {
        guard validateInputsForAction(requireModel: true) else { return }
        isTestingConnection = true
        let baseURL = trimmedBaseURL
        let modelName = trimmedModelName
        let apiKey = trimmedAPIKey
        testConnectionTask?.cancel()
        testConnectionTask = Task {
            do {
                try await aiService.testConnection(
                    baseURL: baseURL,
                    modelName: modelName,
                    apiKey: apiKey
                )
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isTestingConnection = false
                    feedback = CCSpaceFeedbackFactory.actionSuccess("连接成功，模型 \(modelName) 可用")
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isTestingConnection = false
                    feedback = CCSpaceFeedbackFactory.actionError(action: "测试连接", error: error)
                }
            }
        }
    }

    /// 动作前置校验;requireModel 为 false 时允许模型名暂空(如先拉列表再选模型)。
    private func validateInputsForAction(requireModel: Bool) -> Bool {
        if trimmedBaseURL.isEmpty {
            feedback = CCSpaceFeedback(style: .error, message: "请先填写 Base URL")
            return false
        }
        if requireModel && trimmedModelName.isEmpty {
            feedback = CCSpaceFeedback(style: .error, message: "请先填写模型名")
            return false
        }
        if trimmedAPIKey.isEmpty {
            feedback = CCSpaceFeedback(style: .error, message: "请先填写 API Key")
            return false
        }
        return true
    }
}

/// 模型下拉弹层的展示状态(纯逻辑,便于测试)。
struct ModelPickerPresentationState {
    static let rowHeight: CGFloat = 28
    /// 列表区最大高度(8 行 + 上下留白),超过即内部滚动。
    static let maxListHeight: CGFloat = rowHeight * 8 + 8

    let filteredModels: [String]

    init(models: [String], searchText: String) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filteredModels = models
        } else {
            filteredModels = models.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    var listHeight: CGFloat {
        min(CGFloat(filteredModels.count) * Self.rowHeight + 8, Self.maxListHeight)
    }

    var footCountText: String {
        "\(filteredModels.count) 个模型"
    }
}

/// 模型下拉弹层:搜索 + 勾选行 + 底部计数,与分支弹窗同一套骨架。
private struct ModelPickerPopoverContent: View {
    let models: [String]
    let currentModel: String
    let onSelect: (String) -> Void

    @State private var searchText = ""

    private var state: ModelPickerPresentationState {
        ModelPickerPresentationState(models: models, searchText: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if state.filteredModels.isEmpty {
                Text("无匹配模型")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.filteredModels, id: \.self) { model in
                            ModelPickerRow(
                                model: model,
                                isSelected: model == currentModel,
                                onSelect: { onSelect(model) }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(height: state.listHeight)
                .animation(.snappy(duration: 0.2), value: state.listHeight)
            }

            Divider()

            HStack {
                Text(state.footCountText)
                Spacer()
                Text("来自服务列表")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 26)
        }
    }

    /// 搜索框与分支弹窗同款样式。
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索模型", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ccspaceQuickHelp("清空搜索")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ModelPickerRow: View {
    let model: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // 勾选列与分支弹窗对齐:未选中用透明占位图,行内模型名左对齐一致。
                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Image(nsImage: MenuPlaceholderIcon.blank)
                    }
                }
                .frame(width: 14)

                Text(model)
                    .font(isSelected ? .callout.weight(.medium) : .callout)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: ModelPickerPresentationState.rowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.10) }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }
}
