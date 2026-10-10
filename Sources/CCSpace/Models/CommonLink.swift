import Foundation

/// 用户自定义的常用链接(标题 + http(s) 地址),仓库级(RepositoryConfig.links)
/// 与工作区级(Workplace.links)两套共用。
struct CommonLink: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var url: String

    init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// 常用链接录入区的纯逻辑:行校验文案、阻塞判定、保存值归一。
/// 视图(CommonLinksEditor)只做渲染,判定口径全部收在这里(可单测)。
enum CommonLinksInput {
    /// 软上限:消费侧是下拉菜单,再多放不下也失去意义;到达上限后隐藏「添加」入口。
    static let maxCount = 8

    /// 单行校验:返回行内提示文案,nil 表示该行合法(全空行也合法——提交时静默丢弃)。
    static func rowError(title: String, url: String) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty, trimmedURL.isEmpty { return nil }
        if trimmedTitle.isEmpty { return "请填写标题" }
        if trimmedURL.isEmpty { return "请填写链接地址" }
        if isValidURL(trimmedURL) == false { return "链接需以 http:// 或 https:// 开头" }
        return nil
    }

    /// 是否存在非法行(阻塞保存)。全空行不算非法。
    static func hasBlockingError(rows: [CommonLink]) -> Bool {
        rows.contains { rowError(title: $0.title, url: $0.url) != nil }
    }

    /// 保存值:trim 后丢弃全空行、保留其余原序(编辑期新增行的临时 id 一并落盘)。
    static func normalizedForSave(rows: [CommonLink]) -> [CommonLink] {
        rows.compactMap { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = row.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.isEmpty == false || url.isEmpty == false else { return nil }
            return CommonLink(id: row.id, title: title, url: url)
        }
    }

    /// 只收 http/https:这类链接面向浏览器打开(流水线/看板/文档),git 协议地址无意义。
    static func isValidURL(_ url: String) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              let components = URLComponents(string: url),
              let host = components.host, host.isEmpty == false else { return false }
        return true
    }
}
