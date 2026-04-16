import SwiftUI

struct WorkplaceRepositoryRowView: View {
    let state: RepositorySyncState
    let repository: RepositoryConfig?
    let displayName: String
    let currentBranch: String?
    let branchStatus: GitBranchStatusSnapshot?
    let availableBranches: [String]
    let retryRepository: RepositoryConfig?
    let pullRepository: RepositoryConfig?
    let allowsDeleteRepository: Bool
    let onRetry: (RepositoryConfig) -> Void
    let onPull: (RepositoryConfig) -> Void
    let onPush: () -> Void
    let onSwitchBranch: (String) -> Void
    let onSwitchToDefaultBranch: () -> Void
    let onSwitchToWorkBranch: () -> Void
    let showsWorkBranchAction: Bool
    let onMergeDefaultBranchIntoCurrent: () -> Void
    let onCreateMergeRequest: (RepositoryConfig) -> Void
    let actionsDisabled: Bool
    let supportsIDEA: Bool
    let onOpenFinder: (String) -> Void
    let onOpenIDEA: (String) -> Void
    let onOpenTerminal: (String) -> Void
    let onDelete: () -> Void
    @State private var showingDeleteConfirmation = false

    private var presentationState: WorkplaceRepositoryRowPresentationState {
        WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: retryRepository != nil,
            hasPullRepository: pullRepository != nil,
            allowsDeleteRepository: allowsDeleteRepository,
            actionsDisabled: actionsDisabled,
            supportsIDEA: supportsIDEA
        )
    }

    private var branchMenuDisabled: Bool {
        !presentationState.canSwitchBranch || availableBranches.isEmpty
    }

    private var showsPrimaryActionMenuItems: Bool {
        (state.status == .failed && retryRepository != nil) ||
        (state.status == .success && pullRepository != nil && state.hasLocalDirectory) ||
        presentationState.canOpenLocalActions
    }

    private var deleteConfirmationState: WorkplaceRepositoryDeleteConfirmationState {
        WorkplaceRepositoryDeleteConfirmationState(
            repositoryName: displayName,
            localPath: state.localPath
        )
    }

    var body: some View {
        CCSpaceInteractiveCard(selected: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(displayName)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .fixedSize()
                            if let currentBranch {
                                Menu {
                                    branchMenuContent
                                } label: {
                                    RepositoryBranchPill(title: currentBranch)
                                }
                                .menuStyle(.borderlessButton)
                                .disabled(branchMenuDisabled)
                                .ccspaceQuickHelp(availableBranches.isEmpty ? "暂无可切换的本地分支" : "切换分支")
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        RepositoryBranchStatusView(
                            syncStatus: state.status,
                            branchStatus: branchStatus
                        )

                        if state.status == .failed, let retryRepository {
                            Button {
                                onRetry(retryRepository)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .ccspaceIconActionButton()
                            .disabled(!presentationState.canRetryClone)
                            .ccspaceQuickHelp("重试克隆")
                        }

                        if presentationState.canOpenLocalActions {
                            if let repository {
                                Button {
                                    onCreateMergeRequest(repository)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .ccspaceIconActionButton()
                                .disabled(!presentationState.canCreateMergeRequest)
                                .ccspaceQuickHelp("向默认分支创建 MR")
                            }

                            Button {
                                onOpenFinder(state.localPath)
                            } label: {
                                Image(systemName: "finder")
                            }
                            .ccspaceIconActionButton()
                            .ccspaceQuickHelp("在 Finder 中显示")

                            if presentationState.canOpenInIDEA {
                                Button {
                                    onOpenIDEA(state.localPath)
                                } label: {
                                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                                }
                                .ccspaceIconActionButton()
                                .ccspaceQuickHelp("在 IDEA 中打开")
                            }

                            Button {
                                onOpenTerminal(state.localPath)
                            } label: {
                                Image(systemName: "terminal")
                            }
                            .ccspaceIconActionButton()
                            .ccspaceQuickHelp("在终端中打开")
                        }

                        Menu {
                            actionMenuContent
                        } label: {
                            RepositoryOverflowMenuLabel()
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .ccspaceQuickHelp("更多操作")
                    }
                }

                if let lastError = presentationState.visibleErrorMessage {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .alert(
            deleteConfirmationState.title,
            isPresented: $showingDeleteConfirmation
        ) {
            Button(deleteConfirmationState.confirmLabel, role: .destructive) {
                onDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteConfirmationState.message)
        }
    }

    @ViewBuilder
    private var branchMenuContent: some View {
        if availableBranches.isEmpty {
            Text("暂无可切换的本地分支")
        } else {
            ForEach(availableBranches, id: \.self) { branch in
                Button {
                    onSwitchBranch(branch)
                } label: {
                    if branch == currentBranch {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
                .disabled(branch == currentBranch || !presentationState.canSwitchBranch)
            }
        }
    }

    @ViewBuilder
    private var actionMenuContent: some View {
        if let retryRepository, state.status == .failed {
            Button {
                onRetry(retryRepository)
            } label: {
                Label("重新克隆", systemImage: "arrow.clockwise")
            }
            .disabled(!presentationState.canRetryClone)
        }
        if let pullRepository, state.status == .success, state.hasLocalDirectory {
            Button {
                onPull(pullRepository)
            } label: {
                Label("Pull 最新代码", systemImage: "arrow.trianglehead.2.clockwise")
            }
            .disabled(!presentationState.canPullLatest)
        }
        if presentationState.canOpenLocalActions {
            Button {
                onPush()
            } label: {
                Label("Push 到远端", systemImage: "square.and.arrow.up")
            }
            .disabled(!presentationState.canPushToRemote)
            Divider()
            Menu {
                branchMenuContent
            } label: {
                Label("切换分支", systemImage: "arrow.triangle.branch")
            }
            .disabled(branchMenuDisabled)
            Button {
                onSwitchToDefaultBranch()
            } label: {
                Label("切到默认分支", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(!presentationState.canSwitchBranch)
            if showsWorkBranchAction {
                Button {
                    onSwitchToWorkBranch()
                } label: {
                    Label("切到工作分支", systemImage: "hammer.circle")
                }
                .disabled(!presentationState.canSwitchBranch)
            }
            Button {
                onMergeDefaultBranchIntoCurrent()
            } label: {
                Label("合并默认分支到当前分支", systemImage: "arrow.triangle.merge")
            }
            .disabled(!presentationState.canSwitchBranch)
            if let repository {
                Button {
                    onCreateMergeRequest(repository)
                } label: {
                    Label("向默认分支创建 MR", systemImage: "arrow.up.right.square")
                }
                .disabled(!presentationState.canCreateMergeRequest)
            }
            Divider()
            Button {
                onOpenFinder(state.localPath)
            } label: {
                Label("在 Finder 中显示", systemImage: "finder")
            }
            if presentationState.canOpenInIDEA {
                Button {
                    onOpenIDEA(state.localPath)
                } label: {
                    Label("在 IDEA 中打开", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            Button {
                onOpenTerminal(state.localPath)
            } label: {
                Label("在终端中打开", systemImage: "terminal")
            }
        }
        if showsPrimaryActionMenuItems {
            Divider()
        }
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("删除仓库", systemImage: "trash")
        }
        .disabled(!presentationState.canDeleteRepository)
    }
}

private struct RepositoryBranchPill: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2.weight(.semibold))
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 200)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

private struct RepositoryOverflowMenuLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var foregroundColor: Color {
        guard isEnabled else { return Color.secondary.opacity(0.42) }
        return isHovering ? .primary : .secondary
    }

    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(foregroundColor)
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
            .opacity(isHovering && isEnabled ? 0.92 : 0.68)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct RepositoryBranchStatusView: View {
    let syncStatus: SyncStatus
    let branchStatus: GitBranchStatusSnapshot?

    var body: some View {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: syncStatus,
            branchStatus: branchStatus
        )

        Group {
            if let activityTitle = summary.activityTitle {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(activityTitle)
                }
                .font(.caption)
                .foregroundStyle(summary.activityTint)
                .accessibilityLabel("状态：\(activityTitle)")
            } else {
                HStack(spacing: 4) {
                    ForEach(summary.pills) { pill in
                        RepositoryBranchStatePill(title: pill.title, tint: pill.tint)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "分支状态：\(summary.pills.map(\.title).joined(separator: "，"))"
                )
            }
        }
    }
}

private struct RepositoryBranchStatusSummary {
    let syncStatus: SyncStatus
    let branchStatus: GitBranchStatusSnapshot?

    var activityTitle: String? {
        syncStatus.activityTitle
    }

    var activityTint: Color {
        syncStatus.activityTint
    }

    var showsActivity: Bool {
        activityTitle != nil
    }

    var pills: [RepositoryBranchStatePillModel] {
        if let branchStatus {
            var pills: [RepositoryBranchStatePillModel] = []
            if branchStatus.hasUncommittedChanges {
                pills.append(.init(title: "未提交", tint: .orange))
            }
            if branchStatus.hasUnpushedCommits {
                pills.append(.init(title: "未推送", tint: .blue))
            }
            if branchStatus.isBehindRemote {
                pills.append(.init(title: "落后远端", tint: .secondary))
            }
            if branchStatus.hasRemoteTrackingBranch == false {
                pills.append(.init(title: "未关联远端", tint: .secondary))
            }
            if pills.isEmpty {
                pills.append(.init(title: "干净", tint: .green))
            }
            return pills
        }

        switch syncStatus {
        case .idle:
            return [.init(title: "未克隆", tint: .secondary)]
        case .failed:
            return [.init(title: "异常", tint: .red)]
        case .success:
            return [.init(title: "状态未知", tint: .secondary)]
        case .cloning, .pulling, .removing:
            return []
        }
    }
}

private enum PillTint {
    case red, orange, blue, green, secondary

    var foreground: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .blue: .blue
        case .green: .green
        case .secondary: .secondary
        }
    }

    var background: Color {
        switch self {
        case .red: Color.red.opacity(0.10)
        case .orange: Color.orange.opacity(0.10)
        case .blue: Color.blue.opacity(0.10)
        case .green: Color.green.opacity(0.10)
        case .secondary: Color.primary.opacity(0.035)
        }
    }
}

private struct RepositoryBranchStatePillModel: Identifiable {
    let title: String
    let tint: PillTint

    var id: String { title }
}

private struct RepositoryBranchStatePill: View {
    let title: String
    let tint: PillTint

    var body: some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.background, in: Capsule())
            .foregroundStyle(tint.foreground)
    }
}

private extension SyncStatus {
    var activityTitle: String? {
        switch self {
        case .idle:
            return nil
        case .cloning:
            return "克隆中"
        case .pulling:
            return "同步中"
        case .success:
            return nil
        case .failed:
            return nil
        case .removing:
            return "移除中"
        }
    }

    var activityTint: Color {
        switch self {
        case .cloning, .removing:
            return .orange
        case .pulling:
            return .blue
        case .idle, .success, .failed:
            return .secondary
        }
    }
}
