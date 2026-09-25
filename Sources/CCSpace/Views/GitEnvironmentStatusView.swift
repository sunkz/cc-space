import SwiftUI

/// 设置页工具栏的 git 环境指示器:图标 + 简短版本号,
/// 悬停查看完整版本与可执行文件路径,点击重新检测。
struct GitEnvironmentStatusView: View {
    let gitService: GitServicing

    /// 默认 true:首帧即呈现检测中状态,避免闪现"不可用"。
    @State private var info: GitEnvironmentInfo?
    @State private var isChecking = true

    private var state: GitEnvironmentPresentationState {
        GitEnvironmentPresentationState(info: info, isChecking: isChecking)
    }

    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Button {
            // 持有句柄:连点时取消上一次探测,避免旧结果后到覆盖新结果(last-write-wins)。
            checkTask?.cancel()
            checkTask = Task { await check() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.availability.statusIconName)
                    .foregroundStyle(state.availability.statusTint)
                if let compactLabel = state.compactLabel {
                    Text(compactLabel)
                        .foregroundStyle(.secondary)
                }
            }
            // caption 与旁边" x 个仓库" pill 的字号一致。
            .font(.caption)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ccspaceQuickHelp(state.quickHelpText)
        .accessibilityLabel("git 环境：\(state.availability.statusText)")
        // 首探也挂进句柄:裸 .task 不占 checkTask,期间点按钮取消的是 nil,
        // 两次探测并发跑、旧结果仍可能后到覆盖,绕过 last-write-wins 防线。
        .task {
            checkTask?.cancel()
            checkTask = Task { await check() }
        }
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
        }
    }

    private func check() async {
        isChecking = true
        let result = await gitService.gitEnvironmentInfo()
        // cancel 只是"没人等它":git 探测返回后必须自查,否则旧一次探测的
        // 结果仍会后到覆盖新结果,last-write-wins 竞态并没有被句柄取消解决。
        guard Task.isCancelled == false else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            info = result
            isChecking = false
        }
    }
}

private extension GitEnvironmentPresentationState.Availability {
    var statusText: String {
        switch self {
        case .checking: return "检测中…"
        case .available: return "可用"
        case .unavailable: return "不可用"
        }
    }

    var statusIconName: String {
        switch self {
        case .checking: return "hourglass"
        case .available: return "checkmark.circle.fill"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    var statusTint: Color {
        switch self {
        case .checking: return .secondary
        case .available: return .green
        case .unavailable: return .orange
        }
    }
}
