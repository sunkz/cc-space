import Foundation

/// 仓库只读信息查询(提交记录 / Stash 列表 / 远端分支建议 / 远端默认分支),
/// 供仓库行视图与设置页仓库区使用:View 不直接触碰 GitServicing 全量协议。
/// 目录存在性判断复用 FileSystemServicing 扩展的统一实现;
/// 本服务只做只读探测,协议要求的写方法委托给 FileSystemService。
struct RepositoryInfoService: FileSystemServicing {
    let gitService: GitServicing
    private let fileSystem = FileSystemService()

    /// 最近提交;本地目录不存在时返回 nil(调用方据此展示目录缺失错误)。
    /// rev 非 nil 时查询指定 ref(分支裸名 / origin/ 跟踪名)。
    func recentCommits(localPath: String, limit: Int, rev: String? = nil) async -> [GitCommitEntry]? {
        guard directoryExists(at: localPath) else { return nil }
        return await gitService.recentCommits(in: localPath, count: limit, rev: rev)
    }

    /// 当前分支未推送的提交;本地目录不存在时返回 nil。rev 非 nil 时按该 ref 与其上游比较。
    func unpushedCommits(localPath: String, limit: Int, rev: String? = nil) async -> [GitCommitEntry]? {
        guard directoryExists(at: localPath) else { return nil }
        return await gitService.unpushedCommits(in: localPath, count: limit, rev: rev)
    }

    /// Stash 列表;本地目录不存在时返回 nil。
    func stashList(localPath: String) async -> [GitStashEntry]? {
        guard directoryExists(at: localPath) else { return nil }
        return await gitService.stashList(in: localPath)
    }

    /// 本地分支元数据(最后提交时间 / 领先落后上游);本地目录不存在时返回 nil。
    func branchMetadata(localPath: String) async -> [String: GitBranchMetadata]? {
        guard directoryExists(at: localPath) else { return nil }
        return await gitService.branchMetadata(in: localPath)
    }

    /// 可切换的远端分支列表:优先读本地 origin(与实际仓库一致),
    /// 无本地远端配置时回退到仓库配置地址;无法确定远端时返回 nil。
    /// 列表为 nil 表示"探测失败"(区别于空数组的"远端确无分支"),调用方可据此保留旧缓存。
    func remoteBranchSuggestions(localPath: String, configuredURL: String?) async -> [String]? {
        let localOrigin = await gitService.remoteURL(in: localPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = (localOrigin?.isEmpty == false) ? localOrigin : configuredURL
        guard let remoteURL, remoteURL.isEmpty == false else { return nil }
        return await gitService.remoteBranches(for: remoteURL)
    }

    /// 远端默认分支(建档后与打开 MR 面板时回补仓库配置用)。
    func defaultBranch(for remoteURL: String) async -> String? {
        await gitService.defaultBranch(for: remoteURL)
    }

    /// 仓库的实际 origin 地址;目录不存在或无 origin 时返回 nil。
    ///
    /// 供"打开仓库网页/创建 MR"这类入口决定用真实远端还是配置地址:克隆后改过
    /// 远端(如迁 fork)时两个入口不能指向不同仓库。放在本服务里,View 侧
    /// 不再直接 `gitService.remoteURL(...)`(AGENTS.md:View 不直接调 git)。
    func remoteURL(localPath: String) async -> String? {
        guard directoryExists(at: localPath) else { return nil }
        return await gitService.remoteURL(in: localPath)
    }

    /// 远端分支列表;`nil` 表示探测失败(调用方保留旧缓存),`[]` 是远端确无分支。
    func remoteBranches(for remoteURL: String) async -> [String]? {
        await gitService.remoteBranches(for: remoteURL)
    }

    func createDirectory(at path: String) throws {
        try fileSystem.createDirectory(at: path)
    }

    func removeItem(at path: String) throws {
        try fileSystem.removeItem(at: path)
    }
}
