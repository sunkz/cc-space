import SwiftUI

/// Stash 列表 popover:逐条恢复(pop)或删除(drop)。纯展示组件,数据加载由宿主负责;
/// 删除需宿主二次确认(popover 内嵌 alert 体验不佳)。
struct StashListPopoverView: View {
    let repositoryName: String
    let entries: [GitStashEntry]
    let isLoading: Bool
    var error: String? = nil
    var actionsDisabled: Bool = false
    var onRetry: (() -> Void)? = nil
    let onPop: (Int) -> Void
    let onRequestDrop: (GitStashEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                loadingView
            } else if let error {
                errorView(error)
            } else if entries.isEmpty {
                emptyView
            } else {
                stashList
            }
        }
        .frame(idealWidth: 380, maxWidth: 460, idealHeight: 320, maxHeight: 440)
    }

    private var header: some View {
        HStack {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            Text(repositoryName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(entries.count) 条 Stash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Spacer()
            Text("暂无 Stash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("可通过仓库菜单中的「Stash 改动」保存当前未提交的修改")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.red)
            Text("加载 Stash 列表失败")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("重试", action: onRetry)
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var stashList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    StashRowView(
                        entry: entry,
                        actionsDisabled: actionsDisabled,
                        onPop: { onPop(entry.index) },
                        onRequestDrop: { onRequestDrop(entry) }
                    )
                    if entry.id != entries.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

private struct StashRowView: View {
    let entry: GitStashEntry
    var actionsDisabled: Bool = false
    let onPop: () -> Void
    let onRequestDrop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                Text(entry.ref)
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                Text(entry.date.relativeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onPop()
                } label: {
                    Label("恢复", systemImage: "tray.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(actionsDisabled)
                .ccspaceQuickHelp("恢复该 Stash 到工作区，并从列表移除；冲突时 Stash 会被保留")
                Button {
                    onRequestDrop()
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(actionsDisabled)
                .ccspaceQuickHelp("删除该 Stash，不可恢复")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
