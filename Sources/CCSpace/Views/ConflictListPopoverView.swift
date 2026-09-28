import SwiftUI

/// 冲突文件列表 popover:展示未合并(冲突)文件与中止入口的纯展示组件。
/// 数据来自状态快照的 unmergedPaths,无需异步加载;
/// 中止操作有破坏性(丢弃合并结果),二次确认由宿主负责。
struct ConflictListPopoverView: View {
    let repositoryName: String
    let unmergedPaths: [String]
    var interruptedOperation: GitInterruptedOperation? = nil
    var actionsDisabled: Bool = false
    let onRequestAbort: () -> Void

    /// 中止按钮文案;操作类型未知(快照尚未探测到)时退化为通用文案。
    private var abortButtonTitle: String {
        interruptedOperation.map { "中止\($0.displayName)" } ?? "中止当前操作"
    }

    private var footnote: String {
        let operationName = interruptedOperation?.displayName ?? "合并/变基"
        return "「\(operationName)」过程中产生了冲突：在编辑器中解决以下文件后提交，或中止回到操作前的状态。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            conflictList
            Divider()
            footer
        }
        .frame(idealWidth: 380, maxWidth: 460, idealHeight: 300, maxHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(repositoryName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(unmergedPaths.count) 个冲突文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var conflictList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(unmergedPaths, id: \.self) { path in
                    ConflictFileRowView(filePath: path)
                    if path != unmergedPaths.last {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    onRequestAbort()
                } label: {
                    Label(abortButtonTitle, systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(actionsDisabled || interruptedOperation == nil)
                .ccspaceQuickHelp(
                    actionsDisabled
                        ? "仓库操作进行中，暂不可中止"
                        : interruptedOperation == nil
                            ? "操作类型识别中，请稍候"
                            : "丢弃本次\(interruptedOperation?.displayName ?? "操作")及已做的冲突解决，回到操作前的状态"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ConflictFileRowView: View {
    let filePath: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.red)
            Text((filePath as NSString).lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            // 目录前缀用次要色弱化展示,长路径下仍能看清是哪个目录下的同名文件。
            if let directory = filePath.split(separator: "/").dropLast().joined(separator: "/") as String?,
               directory.isEmpty == false {
                Text(directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .textSelection(.enabled)
    }
}
