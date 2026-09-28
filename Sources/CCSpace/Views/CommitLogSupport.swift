import Foundation

/// 提交记录 popover 的展示状态:按关键词过滤提交、计数与空态文案。
/// "仅看未推送"切换数据源(全量 / @{u}..HEAD),关键词过滤始终在已加载的列表上进行。
struct CommitLogPresentationState: Equatable {
    enum Scope: Equatable {
        case all
        case unpushedOnly
    }

    let filteredCommits: [GitCommitEntry]
    let countLabel: String
    let emptyTitle: String
    let emptySubtitle: String
    let canFilterUnpushed: Bool
    let unpushedToggleHelp: String

    init(
        commits: [GitCommitEntry],
        searchText: String,
        scope: Scope,
        hasUpstream: Bool,
        isRemoteTrackingRef: Bool = false
    ) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSearchText.isEmpty {
            filteredCommits = commits
        } else {
            filteredCommits = commits.filter { entry in
                entry.subject.localizedCaseInsensitiveContains(trimmedSearchText)
                    || entry.author.localizedCaseInsensitiveContains(trimmedSearchText)
                    || entry.hash.localizedCaseInsensitiveContains(trimmedSearchText)
            }
        }

        let unit = scope == .unpushedOnly ? "条未推送提交" : "条提交"
        countLabel = "\(filteredCommits.count) \(unit)"

        if commits.isEmpty {
            if scope == .unpushedOnly {
                emptyTitle = "没有未推送的提交"
                emptySubtitle = "当前分支的提交都已推送到远端"
            } else {
                emptyTitle = "暂无提交记录"
                emptySubtitle = ""
            }
        } else {
            emptyTitle = "未找到匹配提交"
            emptySubtitle = "试试提交说明、作者或 commit ID 中的关键词。"
        }

        canFilterUnpushed = hasUpstream
        // 浏览 origin/x 这类远端跟踪引用时,"未推送"筛选本就不适用,
        // 不能误归因为"当前分支未关联远端"。
        if hasUpstream {
            unpushedToggleHelp = "只看当前分支尚未推送到上游的提交"
        } else if isRemoteTrackingRef {
            unpushedToggleHelp = "正在浏览远端跟踪分支，无法筛选未推送提交"
        } else {
            unpushedToggleHelp = "当前分支未关联远端，无法筛选未推送提交"
        }
    }
}

extension Date {
    /// 面向用户的相对时间描述(刚刚 / N 分钟前 / … / 超过 30 天时退化为日期)。
    /// 全 App 相对时间的唯一实现;WorkplaceRelativeTimeFormatter 亦委托于此。
    var relativeDescription: String {
        relativeDescription(now: .now, calendar: .current)
    }

    func relativeDescription(now: Date, calendar: Calendar) -> String {
        let interval = now.timeIntervalSince(self)
        guard interval >= 0 else { return "刚刚" }

        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)

        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if hours < 24 { return "\(hours) 小时前" }
        if days < 30 { return "\(days) 天前" }

        return WorkplaceRelativeTimeFormatter.absoluteDateText(self, now: now, calendar: calendar)
    }
}
