import SwiftUI

/// 常用链接录入区:每行「标题 + 地址 + ✕」,底部「+ 添加链接」追加空行。
/// 校验文案/保存归一全部收在 `CommonLinksInput`(纯函数可单测),视图只渲染。
/// 四处复用:新增/编辑仓库弹窗、创建/编辑工作区表单。
struct CommonLinksEditor: View {
    @Binding var rows: [CommonLink]
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TextField("标题", text: $row.title)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .disabled(isDisabled)
                        TextField("https://…", text: $row.url)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isDisabled)
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isDisabled)
                        .accessibilityLabel("删除该链接")
                    }
                    // 填一半/地址非法的行内即时提示;全空行合法(提交时静默丢弃)。
                    if let error = CommonLinksInput.rowError(title: row.title, url: row.url) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if rows.count < CommonLinksInput.maxCount {
                Button {
                    rows.append(CommonLink(title: "", url: ""))
                } label: {
                    Label("添加链接", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(isDisabled)
            }
        }
    }
}
