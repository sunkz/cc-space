import Foundation

/// 仓库只读信息查询(提交记录 / Stash 列表 / 远端分支建议 / 远端探测),
/// 供仓库行视图与新增/编辑表单弹层使用:View 不直接触碰 GitServicing 全量协议。
struct RepositoryInfoService: Sendable {
    let gitService: GitServicing

    /// 最近提交;本地目录不存在时返回 nil(调用方据此展示目录缺失错误)。
    /// rev 非 nil 时查询指定 ref(分支裸名 / origin/ 跟踪名)。
    func recentCommits(localPath: String, limit: Int, rev: String? = nil) async -> [GitCommitEntry]? {
        guard directoryExists(localPath) else { return nil }
        return await gitService.recentCommits(in: localPath, count: limit, rev: rev)
    }

    /// 当前分支未推送的提交;本地目录不存在时返回 nil。rev 非 nil 时按该 ref 与其上游比较。
    func unpushedCommits(localPath: String, limit: Int, rev: String? = nil) async -> [GitCommitEntry]? {
        guard directoryExists(localPath) else { return nil }
        return await gitService.unpushedCommits(in: localPath, count: limit, rev: rev)
    }

    /// Stash 列表;本地目录不存在时返回 nil。
    func stashList(localPath: String) async -> [GitStashEntry]? {
        guard directoryExists(localPath) else { return nil }
        return await gitService.stashList(in: localPath)
    }

    /// 本地分支元数据(最后提交时间 / 领先落后上游);本地目录不存在时返回 nil。
    func branchMetadata(localPath: String) async -> [String: GitBranchMetadata]? {
        guard directoryExists(localPath) else { return nil }
        return await gitService.branchMetadata(in: localPath)
    }

    /// 可切换的远端分支列表:优先读本地 origin(与实际仓库一致),
    /// 无本地远端配置时回退到仓库配置地址;无法确定远端时返回 nil。
    func remoteBranchSuggestions(localPath: String, configuredURL: String?) async -> [String]? {
        let localOrigin = await gitService.remoteURL(in: localPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = (localOrigin?.isEmpty == false) ? localOrigin : configuredURL
        guard let remoteURL, remoteURL.isEmpty == false else { return nil }
        return await gitService.remoteBranches(for: remoteURL)
    }

    /// 新增/编辑表单的远端探测:分支列表与默认分支合并为一次探测
    /// (真实 GitService 只跑一条 `ls-remote --symref`,省一半网络往返;
    /// URL 合法性守卫在 GitService.probeRemoteInfo 内保持)。
    func probeRemote(gitURL: String) async -> (branches: [String], defaultBranch: String?) {
        await gitService.probeRemoteInfo(for: gitURL)
    }

    /// 远端默认分支(表单编辑回填用)。
    func defaultBranch(for remoteURL: String) async -> String? {
        await gitService.defaultBranch(for: remoteURL)
    }

    /// 远端分支列表。
    func remoteBranches(for remoteURL: String) async -> [String] {
        await gitService.remoteBranches(for: remoteURL)
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
