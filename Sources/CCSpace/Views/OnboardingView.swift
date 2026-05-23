import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var repositoryStore: RepositoryStore
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = .rootDirectory
    @State private var rootPath: String = ""
    @State private var gitURLInput: String = ""
    @State private var addedRepositoryIDs: [UUID] = []
    @State private var feedback: CCSpaceFeedback?
    @State private var appeared = false

    enum OnboardingStep: Int, CaseIterable {
        case rootDirectory = 0
        case addRepositories = 1
        case createWorkplace = 2

        var title: String {
            switch self {
            case .rootDirectory: return "选择工作区根目录"
            case .addRepositories: return "添加 Git 仓库"
            case .createWorkplace: return "准备就绪"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.top, 28)
                .padding(.horizontal, 48)

            Spacer(minLength: 20)

            stepContent
                .frame(maxWidth: 480)
                .padding(.horizontal, 48)

            Spacer(minLength: 20)

            footerBar
                .padding(.horizontal, 48)
                .padding(.bottom, 28)
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 440, idealHeight: 500)
        .background(onboardingBackground)
        .onAppear {
            rootPath = settingsStore.settings.workplaceRootPath
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                appeared = true
            }
        }
    }

    // MARK: - Background

    private var onboardingBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.04), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -8)

            Text("欢迎使用 CCSpace")
                .font(.title.weight(.semibold))
                .opacity(appeared ? 1 : 0)

            stepIndicator
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                let isCurrent = step == currentStep
                let isPast = step.rawValue < currentStep.rawValue
                Capsule()
                    .fill(isCurrent ? Color.accentColor : isPast ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.1))
                    .frame(width: isCurrent ? 24 : 8, height: 6)
                    .animation(.snappy(duration: 0.3), value: currentStep)
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .rootDirectory:
            rootDirectoryStep
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
        case .addRepositories:
            addRepositoriesStep
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
        case .createWorkplace:
            createWorkplaceStep
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
        }
    }

    private var rootDirectoryStep: some View {
        VStack(spacing: 16) {
            stepTitle(
                icon: "folder.badge.gearshape",
                title: "选择工作区根目录",
                subtitle: "CCSpace 会在此目录下为每个工作区创建子文件夹。"
            )

            VStack(spacing: 12) {
                directoryDisplay

                Button {
                    chooseRootDirectory()
                } label: {
                    Label(rootPath.isEmpty ? "选择目录…" : "更换目录…", systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var directoryDisplay: some View {
        if rootPath.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("尚未选择目录")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(rootPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var addRepositoriesStep: some View {
        VStack(spacing: 16) {
            stepTitle(
                icon: "shippingbox.fill",
                title: "添加 Git 仓库",
                subtitle: "手动添加仓库地址，或从已有备份文件中导入。"
            )

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("粘贴 Git 仓库地址", text: $gitURLInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addRepository() }

                    Button("添加") { addRepository() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(gitURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                    Text("或")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                }

                Button {
                    importRepositoriesBackup()
                } label: {
                    Label("从备份文件导入", systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                if let feedback {
                    CCSpaceFeedbackBanner(feedback: feedback)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                repositoryList
            }
            .padding(16)
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var repositoryList: some View {
        if addedRepositoryIDs.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.yellow)
                    .font(.callout)
                Text("可跳过此步，稍后在设置中添加")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } else {
            let repos = repositoryStore.repositories.filter { addedRepositoryIDs.contains($0.id) }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(repos) { repo in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                            Text(repo.repoName)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(repo.gitURL)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private var createWorkplaceStep: some View {
        VStack(spacing: 16) {
            stepTitle(
                icon: "checkmark.seal.fill",
                title: "准备就绪",
                subtitle: "配置完成，可以开始使用 CCSpace 了。"
            )

            VStack(spacing: 10) {
                summaryRow(
                    icon: "folder.fill",
                    iconColor: rootPath.isEmpty ? .orange : .green,
                    label: "根目录",
                    value: rootPath.isEmpty ? "未设置" : rootPath,
                    valueStyle: rootPath.isEmpty ? .warning : .normal
                )
                summaryRow(
                    icon: "shippingbox.fill",
                    iconColor: repositoryStore.repositories.isEmpty ? .secondary : .green,
                    label: "仓库",
                    value: repositoryStore.repositories.isEmpty ? "暂无" : "\(repositoryStore.repositories.count) 个",
                    valueStyle: .normal
                )
            }
            .padding(16)
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

            if rootPath.isEmpty {
                Label("建议返回第一步设置根目录", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Shared Components

    private func stepTitle(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .padding(.bottom, 4)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private enum SummaryValueStyle {
        case normal, warning
    }

    private func summaryRow(icon: String, iconColor: Color, label: String, value: String, valueStyle: SummaryValueStyle) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(valueStyle == .warning ? Color.orange : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            if currentStep.rawValue > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.3)) {
                        currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .rootDirectory
                    }
                } label: {
                    Label("上一步", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            }

            Spacer()

            if currentStep == .createWorkplace {
                Button {
                    completeOnboarding()
                } label: {
                    Text("开始使用 CCSpace")
                        .font(.callout.weight(.medium))
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else {
                Button("跳过") {
                    advanceStep()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .font(.callout)

                Button {
                    advanceStep()
                } label: {
                    Label("继续", systemImage: "chevron.right")
                        .font(.callout.weight(.medium))
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
    }

    // MARK: - Logic

    private var canAdvance: Bool {
        switch currentStep {
        case .rootDirectory:
            return !rootPath.isEmpty
        case .addRepositories, .createWorkplace:
            return true
        }
    }

    private func advanceStep() {
        feedback = nil
        withAnimation(.snappy(duration: 0.3)) {
            if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                currentStep = next
            }
        }
    }

    private func completeOnboarding() {
        try? settingsStore.updateHasCompletedOnboarding(true)
        onComplete()
    }

    private func chooseRootDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if let errorMessage = settingsStore.saveRootPathAndReturnErrorMessage(path) {
            feedback = CCSpaceFeedback(style: .error, message: errorMessage)
        } else {
            rootPath = path
            feedback = nil
        }
    }

    private func addRepository() {
        let trimmed = gitURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try repositoryStore.addRepository(gitURL: trimmed)
            if let newRepo = repositoryStore.repositories.first(where: { $0.gitURL == trimmed }) {
                withAnimation(.snappy(duration: 0.25)) {
                    addedRepositoryIDs.append(newRepo.id)
                }
            }
            gitURLInput = ""
            feedback = CCSpaceFeedback(style: .success, message: "已添加")
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "添加仓库", error: error)
        }
    }

    private func importRepositoriesBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let countBefore = repositoryStore.repositories.count
            let result = try repositoryStore.importBackup(from: url)
            let newRepos = repositoryStore.repositories.suffix(repositoryStore.repositories.count - countBefore)
            withAnimation(.snappy(duration: 0.25)) {
                addedRepositoryIDs.append(contentsOf: newRepos.map(\.id))
            }
            if result.importedCount > 0 {
                feedback = CCSpaceFeedback(style: .success, message: "已导入 \(result.importedCount) 个仓库")
            } else if result.mergedCount > 0 {
                feedback = CCSpaceFeedback(style: .info, message: "已合并 \(result.mergedCount) 个仓库配置")
            } else {
                feedback = CCSpaceFeedback(style: .info, message: "备份中的仓库均已存在")
            }
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "导入备份", error: error)
        }
    }
}
