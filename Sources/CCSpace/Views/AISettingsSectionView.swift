import SwiftUI

/// 设置页「AI 服务」区块:配置 OpenAI 兼容服务,供提交信息生成等 AI 功能共用。
///
/// 服务地址、模型名与 API Key 明文保存在 settings.json(数据目录/文件已收紧为
/// 仅本人可读写);表单回显即已存值,所见即所存。
/// 支持从服务拉取模型列表选择、测试连接。
struct AISettingsSection: View {
    @ObservedObject private var settingsStore: SettingsStore
    private let aiService: AIServiceInfoServicing
    /// 未保存修改的上报通道:由 RootSplitView 持有、经 SettingsView 注入,
    /// 驱动标题栏 AI 页签的「•」标记。本视图只报状态,不关心展示位置。
    @Binding private var hasUnsavedChanges: Bool

    @State private var baseURLText: String
    @State private var modelNameText: String
    /// API Key 输入;初始化时回显已保存值(SecureField 按字符显示掩码),所见即所存。
    @State private var apiKeyText: String
    /// 明文显示 API Key(默认掩码):掩码下粘贴错一个字符无从核对。
    @State private var showsAPIKeyPlain = false
    @State private var feedback: CCSpaceFeedback?
    @State private var isTestingConnection = false
    @State private var isFetchingModels = false
    @State private var showsModelPicker = false
    @State private var fetchedModels: [String] = []
    /// 网络请求任务句柄:视图消失(含切换设置页签)时取消,避免迟到回调写已离场视图的状态。
    @State private var fetchModelsTask: Task<Void, Never>?
    @State private var testConnectionTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        aiService: AIServiceInfoServicing,
        hasUnsavedChanges: Binding<Bool>
    ) {
        self.settingsStore = settingsStore
        self.aiService = aiService
        self._hasUnsavedChanges = hasUnsavedChanges
        let aiSettings = settingsStore.settings.aiSettings
        _baseURLText = State(initialValue: aiSettings?.baseURL ?? "")
        _modelNameText = State(initialValue: aiSettings?.modelName ?? "")
        _apiKeyText = State(initialValue: aiSettings?.apiKey ?? "")
    }

    private var trimmedAPIKey: String {
        apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 表单展示状态:与已存配置逐字段比对(输入框初值即来自已存配置)。
    private var formState: AISettingsFormPresentationState {
        AISettingsFormPresentationState(
            baseURL: baseURLText,
            modelName: modelNameText,
            apiKey: apiKeyText,
            stored: settingsStore.settings.aiSettings
        )
    }

    private var isDirty: Bool {
        formState.isDirty
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
        // initial: true 保证首帧即对齐:上次离开设置页若带着未保存修改,
        // onDisappear 的复位与本次进入的首帧存在时序窗口,首帧必须补报一次。
        .onChange(of: isDirty, initial: true) { _, newValue in
            hasUnsavedChanges = newValue
        }
        .onDisappear {
            // 视图从视图树移除(设置页整体关闭)时取消在途请求并复位进行中状态。
            // 页签切换不再触发本回调:两页签常驻视图树以保留未保存输入。
            fetchModelsTask?.cancel()
            fetchModelsTask = nil
            testConnectionTask?.cancel()
            testConnectionTask = nil
            isFetchingModels = false
            isTestingConnection = false
            // 离开设置页后表单随视图销毁,标记一并清零,不留陈旧的页签「•」。
            hasUnsavedChanges = false
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

            if isDirty {
                Text("未保存")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("有未保存的修改")
            }

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
            // 无修改时禁用:此前恒可点,点了也只是回一句"已保存";
            // ⌘S 同样只在有未保存修改时生效(disabled 的按钮不接快捷键)。
            .disabled(isDirty == false)
            .keyboardShortcut("s", modifiers: .command)
    }

    // MARK: - 配置表单

    /// API Key 输入组:默认掩码、眼睛按钮切换明文(核对粘贴);
    /// 有密钥可清时给显式「清除密钥」入口,一键删除并落盘,
    /// 不必手动清空输入框再点保存。
    private var apiKeyField: some View {
        HStack(spacing: 6) {
            Group {
                if showsAPIKeyPlain {
                    TextField("sk-…", text: $apiKeyText)
                } else {
                    SecureField("sk-…", text: $apiKeyText)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)

            Button {
                showsAPIKeyPlain.toggle()
            } label: {
                Image(systemName: showsAPIKeyPlain ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .ccspaceQuickHelp(showsAPIKeyPlain ? "隐藏 API Key" : "显示 API Key", providesLabel: true)

            if hasAPIKeyToClear {
                Button("清除密钥") { clearAPIKey() }
                    .ccspaceSecondaryActionButton()
                    .ccspaceQuickHelp("删除已保存的 API Key，Base URL 与模型名保留")
            }
        }
    }

    /// 是否存在可清除的密钥:已存,或输入框里有内容。
    private var hasAPIKeyToClear: Bool {
        if settingsStore.settings.aiSettings?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return trimmedAPIKey.isEmpty == false
    }

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldRow(label: "Base URL") {
                TextField("https://open.bigmodel.cn/api/paas/v4", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    // 与 API Key、模型名同口径:回车即保存。三格只差 baseURL 需要回车确认
                    // 时最容易让人以为"没生效"而再点一次保存按钮。
                    .onSubmit(save)
            }

            fieldRow(label: "API Key") {
                apiKeyField
            }

            fieldRow(label: "模型名") {
                HStack(spacing: 6) {
                    TextField("glm-5.3-flash", text: $modelNameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)

                    fetchModelsButton
                }
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
                Label("选择模型", systemImage: "chevron.up.chevron.down")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isFetchingModels)
        .ccspaceQuickHelp("从服务获取可用模型列表并选择")
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
    /// API Key 不参与校验:本地服务无需密钥(见 AISettingsFormPresentationState)。
    private func validateInputsForAction(requireModel: Bool) -> Bool {
        if let message = AISettingsFormPresentationState.actionValidationError(
            baseURL: trimmedBaseURL,
            modelName: trimmedModelName,
            requireModel: requireModel
        ) {
            feedback = CCSpaceFeedback(style: .error, message: message)
            return false
        }
        return true
    }

    /// 显式删除已保存的 API Key(输入框一并清空并立即落盘),
    /// 不牵动 Base URL/模型名的未保存修改。
    private func clearAPIKey() {
        do {
            try settingsStore.clearStoredAPIKey()
            apiKeyText = ""
            showsAPIKeyPlain = false
            feedback = CCSpaceFeedbackFactory.actionSuccess("已清除保存的 API Key")
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "清除 API Key", error: error)
        }
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
                .ccspaceQuickHelp("清空搜索", providesLabel: true)
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
