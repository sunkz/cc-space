import Foundation
import os

private let gitServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "GitService"
)

enum GitServiceError: LocalizedError, Sendable {
    case commandFailed(exitCode: Int32, stderr: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(_, let stderr):
            if stderr.isEmpty { return "git 执行失败" }
            return Self.localizeMessage(stderr) ?? Self.redactCredentials(in: stderr)
        case .operationFailed(let message):
            return message
        }
    }

    var stderr: String {
        switch self {
        case .commandFailed(_, let stderr): return stderr
        case .operationFailed(let message): return message
        }
    }

    /// 将 git 原始错误信息翻译为用户友好的中文说明。
    /// 未匹配到已知模式返回 nil(调用方保留原始消息并做凭据脱敏)。
    /// internal:`UserFacingError` 据此判断文案是否**真的**已转中文,不靠"是否含汉字"猜。
    static func localizeMessage(_ stderr: String) -> String? {
        let lower = stderr.lowercased()

        if lower.contains("could not read username") || lower.contains("could not read password") {
            return "认证信息缺失，请检查 Git 仓库地址或配置 SSH 密钥"
        }
        if lower.contains("authentication failed") || lower.contains("invalid username or password") {
            return "认证失败，请检查用户名或访问令牌（Token）是否正确"
        }
        if lower.contains("permission denied") && lower.contains("publickey") {
            return "SSH 密钥认证失败，请检查是否已配置 SSH 公钥"
        }
        if lower.contains("host key verification failed") {
            return "远程主机密钥验证失败，可尝试手动连接以信任该主机"
        }
        if lower.contains("could not resolve host") {
            return "无法解析主机地址，请检查网络连接或仓库地址是否正确"
        }
        if lower.contains("connection refused") {
            return "连接被拒绝，请检查远程仓库服务是否正常运行"
        }
        if lower.contains("operation timed out") || lower.contains("connection timed out") {
            return "连接超时，请检查网络连接"
        }
        if lower.contains("unable to access") {
            return "无法访问远程仓库，请检查网络连接和仓库地址"
        }
        // 收紧匹配:"repository" 与 "not found" 必须出现在同一行才算"仓库不存在",
        // 避免无关 stderr 恰好同时含这两个词被误译;"remote:" 前缀(远端输出)单独放宽。
        if lower.components(separatedBy: .newlines).contains(where: { line in
            line.contains("repository") && line.contains("not found")
        }) || (lower.contains("not found") && lower.contains("remote:")) {
            return "远程仓库不存在，请检查仓库地址和访问权限"
        }
        if lower.contains("destination path") && lower.contains("already exists") {
            return "本地目录已存在，请确认仓库未被重复克隆"
        }
        if lower.contains("could not read from remote repository") {
            return "无法读取远程仓库，请检查仓库地址和访问权限"
        }
        if lower.contains("couldn't find remote ref")
            || lower.contains("could not find remote ref")
            || lower.contains("remote ref does not exist") {
            return "远端不存在该分支，请检查分支名称"
        }
        if lower.contains("couldn't find remote") || lower.contains("could not find remote") {
            return "无法找到远端仓库，请检查 remote 配置"
        }
        if lower.contains("cannot lock ref") {
            return "无法锁定引用，可能是并发操作导致，请稍后重试"
        }
        if lower.contains("merge conflict") || (lower.contains("automatic merge failed") && lower.contains("conflict")) {
            return "自动合并失败，存在冲突，请手动解决冲突后提交"
        }
        if lower.contains("refusing to merge unrelated histories") {
            return "拒绝合并不相关历史，两个分支没有共同祖先，可考虑允许无关历史合并"
        }
        if lower.contains("reconcile divergent branches") || lower.contains("divergent branches") {
            return "本地与远端分支已分叉，且该仓库未配置合并策略（pull.rebase），请先配置或手动处理"
        }
        if lower.contains("not a valid object name") || (lower.contains("pathspec") && lower.contains("did not match")) {
            return "分支名或路径不存在，请检查输入是否正确"
        }
        // 新旧版 git 措辞不同:旧版 "checked out at",新版 "used by worktree"。
        if lower.contains("cannot delete branch"),
           lower.contains("checked out") || lower.contains("used by worktree") {
            return "该分支正被检出（当前分支或其他工作区使用中），无法删除"
        }
        if lower.contains("failed to connect") {
            return "连接失败，请检查网络连接和远程仓库地址"
        }
        if lower.contains("nothing to commit") {
            return "没有可提交的改动"
        }
        if lower.contains("please tell me who you are")
            || lower.contains("unable to auto-detect email address")
            || lower.contains("empty ident")
        {
            return "未配置 Git 用户信息（user.name / user.email），请先配置后再提交"
        }
        if lower.contains("fetch") && (lower.contains("cannot open") || lower.contains("unable to open")) {
            return "无法读取仓库文件，仓库可能已损坏"
        }
        if lower.contains("not a git repository") {
            return "该目录不是 Git 仓库（或目录已被移动/删除）"
        }
        if lower.contains("index.lock") && lower.contains("file exists") {
            return "Git 正被其他操作占用（index.lock），请稍后重试"
        }
        if lower.contains("dubious ownership") {
            return "仓库目录属主异常，Git 拒绝操作。可在终端对该目录执行 git config --global --add safe.directory 后重试"
        }
        if lower.contains("would be overwritten by checkout") {
            return "本地有未提交的修改，切换分支会被覆盖。请先提交或暂存（stash）"
        }

        return nil
    }

    /// 匹配 `scheme://user:password@host` 或 `scheme://token@host` 形式的凭据片段。
    /// git 失败时 stderr 普遍会回显整个远端 URL,而用户常把 token 写进 URL
    /// (`https://oauth2:<token>@git.example.com/o/r.git`,或 GitHub 的
    /// `https://ghp_xxx@github.com/o/r.git` —— 用户名即 token,没有冒号段)。
    /// 密码段允许 `/`(base64/URL 风格密钥常见含斜杠)与空格(畸形/未转义的密钥),
    /// 用户名段不允许——无凭据的 `https://host/path` 因"首个 @ 前出现斜杠"不会被误脱敏。
    /// 宁可多打码(端口 `:8080` 后同行出现游离 @ 时会被一并遮掉)也不漏打:
    /// 漏打等于把令牌显示在 UI/日志里。
    private static let credentialPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "[A-Za-z][A-Za-z0-9+.\\-]*://[^/\\s:@]+(?::[^@\\s]+(?: +[^@\\s]+)*)?@",
            options: []
        )
    }()

    /// 把文本中形如 `scheme://user:pass@host` 的凭据替换为 `scheme://redacted@host`。
    ///
    /// 未匹配到已知本地化规则的 stderr 会原样进入错误提示展示给用户,不做脱敏
    /// 等于把访问令牌显示在 UI 上(也可能随日志/截图外泄)。
    static func redactCredentials(in text: String) -> String {
        guard let regex = credentialPattern else { return text }
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text)
        )
        guard matches.isEmpty == false else { return text }

        var result = text
        // 从后往前替换,避免前面的替换改变后面匹配的位置。
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let schemeEnd = result[range].range(of: "://") else { continue }
            let scheme = String(result[range][..<schemeEnd.upperBound])
            result.replaceSubrange(range, with: "\(scheme)redacted@")
        }
        return result
    }

    /// 剔除 OpenSSH 的建议性警告行(如后量子密钥交换提示),它们以 "**" 开头、与命令成败无关,不应进入错误提示。
    static func sanitizedStderr(_ stderr: String) -> String {
        let lines = stderr.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("** ") }
        // 脱敏放在最后:过滤掉的只是噪音行,凭据可能出现在任意一行。
        return redactCredentials(
            in: lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// `trackedStashCreate` 的结果令牌:必须能区分"创建了新暂存"与"未创建"。
/// 只回传栈顶 SHA 不够——`git stash push` 在无本地改动时打印
/// "No local changes to save" 却以退出码 0 结束(与状态检查存在竞态),
/// 此时栈顶是用户既有 stash,恢复侧见栈顶匹配会直接 pop 用户的数据。
enum GitTrackedStash: Equatable, Sendable {
    /// 已创建新暂存;关联值为栈顶 commit SHA,nil 表示标识查询失败
    /// (调用方回退旧的"弹栈顶"语义)。
    case created(sha: String?)
    /// 未创建任何暂存:调用方必须跳过恢复路径。
    case notCreated
}

protocol GitServicing: Sendable {
    func clone(repositoryURL: String, into directory: String) async throws
    func pull(in directory: String) async throws
    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome
    func push(in directory: String) async throws
    func stash(in directory: String) async throws
    func stashPop(in directory: String) async throws
    /// 暂存当前改动(含 untracked)并返回恢复侧可对账的结果令牌
    /// (见 `GitTrackedStash`)。
    func trackedStashCreate(in directory: String) async throws -> GitTrackedStash
    /// 恢复 `trackedStashCreate` 创建的暂存:先校验栈顶仍是该 SHA;
    /// 若被并发操作打乱,则按 SHA 找到对应条目 apply(**不 drop**,错位时的索引已不可信)。
    /// `.created(sha: nil)` 回退 `stashPop`;`.notCreated` 必须是空操作。
    func trackedStashRestore(sha: GitTrackedStash, in directory: String) async throws
    func isGitAvailable() async -> Bool
    func defaultBranch(for remoteURL: String) async -> String?
    func defaultBranch(in directory: String) async -> String?
    func currentBranch(in directory: String) async -> String?
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot?
    func branches(in directory: String) async -> [String]
    /// 本地已有的远端跟踪分支(如 origin/xxx,不含 */HEAD);仅读本地引用,不联网。
    func remoteTrackingBranches(in directory: String) async -> [String]
    func branchSnapshotInfo(in directory: String) async -> BranchSnapshotInfo?
    func remoteURL(in directory: String) async -> String?
    func checkoutBranch(_ branch: String, in directory: String) async throws
    func createLocalBranch(_ branch: String, in directory: String) async throws
    /// 删除本地分支:先按已合并安全删除(`git branch -d`),
    /// 分支含未合并提交时自动回退强制删除(`-D`)。删除前的二次确认由调用方负责。
    func deleteLocalBranch(_ branch: String, in directory: String) async throws
    /// 删除远端分支(`git push origin --delete`),会影响远端仓库上的同名分支,调用方需先确认。
    func deleteRemoteBranch(_ branch: String, in directory: String) async throws
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry]
    /// 当前分支领先上游的提交(`git log @{u}..HEAD`);无上游或执行失败时返回空。
    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry]
    /// 指定 ref(分支裸名 / origin/ 跟踪名)的最近提交;rev 为 nil 时等价于 `recentCommits`。
    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry]
    /// 指定 ref 领先其上游的提交(`<rev>@{u}..<rev>`);ref 无上游或执行失败时返回空。
    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry]
    /// 提交记录窗口的分页查询:关键词过滤与偏移(`--skip`)都下推到 git,
    /// 因此能命中尚未加载进内存的历史提交,而不是只在已加载的首页里筛。
    func commitLogPage(_ request: CommitLogPageRequest) async -> GitCommitLogPage
    /// 远端分支名单;`nil` 表示探测失败(URL 非法/网络失败),空数组是"远端确无分支"。
    /// 调用方据此区分:stale-while-revalidate 的展示方在 nil 时保留旧缓存。
    func remoteBranches(for remoteURL: String) async -> [String]?
    /// 一次远端探测:同时取分支列表与默认分支。真实实现单次
    /// `ls-remote --symref` 完成,省一半网络往返;默认实现回退到分头查询。
    func probeRemoteInfo(for remoteURL: String) async -> (branches: [String], defaultBranch: String?)
    /// Stash 列表(stash@{0} 最新,在前)。
    func stashList(in directory: String) async -> [GitStashEntry]
    /// 手动 Stash 当前改动(含 untracked)。
    func stashPush(in directory: String, message: String) async throws
    /// 恢复指定位置的 Stash 并从列表移除(pop);冲突时 Stash 会被保留。
    func popStash(at index: Int, in directory: String) async throws
    /// 删除指定位置的 Stash,不可恢复。
    func dropStash(at index: Int, in directory: String) async throws
    /// 工作区未提交改动的 diff(包含已暂存和未暂存);失败(含取消/超时)如实抛错,不吞成空 diff。
    func diffWorkingDirectory(in directory: String) async throws -> [GitDiffEntry]
    /// 指定 commit 的 diff(`git show <hash>`);失败(含取消/超时)如实抛错,不吞成空 diff。
    func diffCommit(hash: String, in directory: String) async throws -> [GitDiffEntry]
    /// 两个分支之间的 diff;`head` 为当前分支时包含工作区未提交改动。
    /// 失败(含取消/超时)如实抛错,不吞成空 diff。
    func diffBranches(base: String, head: String, in directory: String) async throws -> [GitDiffEntry]
    /// 两个 ref 的分歧提交数(`rev-list --left-right --count base...head`);ref 非法或执行失败返回 nil。
    func divergence(base: String, head: String, in directory: String) async -> GitRefDivergence?
    /// 指定修订版本中某文件的完整内容(`git cat-file blob`);不存在时返回 nil。
    /// 「展示所有行」用它取 commit/分支对比来源的新侧全文。
    func blobContent(revision: String, path: String, in directory: String) async -> String?
    /// 全部本地分支的元数据(最后提交时间 / 领先落后上游);一次 for-each-ref 扫描。
    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata]
    /// 单个提交的完整详情(标题+正文/邮箱等);hash 非法或提交不存在时返回 nil。
    func commitDetail(hash: String, in directory: String) async -> GitCommitDetail?
    /// 基于指定 ref(commit/分支名)创建并切换到新分支(`git switch -c <branch> <rev>`)。
    func createBranch(_ branch: String, fromRev rev: String, in directory: String) async throws
    /// 以远端分支为基线创建并切换:先 `fetch` 刷新 `origin/<baseBranch>` 引用
    /// (列表来自弹窗打开时的探测,不刷新可能基于过期提交甚至不存在的引用),
    /// 再 `checkout -b <branch> origin/<baseBranch>`。
    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws
    /// 丢弃指定文件的全部未提交改动:修改/删除恢复到 HEAD,未跟踪文件直接删除,不可恢复。
    func discardChanges(filePath: String, in directory: String) async throws
    /// 提交工作区全部改动(含 untracked):`git add --all` 后 `git commit -m`。
    func commitAllChanges(message: String, in directory: String) async throws
    /// 中止当前进行中的合并/变基/cherry-pick/revert/二分操作,返回被中止的操作。
    /// 无进行中操作时抛错;调用方(界面)负责二次确认。
    func abortInterruptedOperation(in directory: String) async throws -> GitInterruptedOperation
    /// git 环境检测(设置页诊断展示用)。
    func gitEnvironmentInfo() async -> GitEnvironmentInfo
}

extension GitServicing {
    // 协议默认实现:便于现有测试替身(stub/spy)无需实现这些方法即可编译通过。
    func remoteTrackingBranches(in directory: String) async -> [String] { [] }
    func diffWorkingDirectory(in directory: String) async -> [GitDiffEntry] { [] }
    func diffCommit(hash: String, in directory: String) async -> [GitDiffEntry] { [] }
    func diffBranches(base: String, head: String, in directory: String) async -> [GitDiffEntry] { [] }
    func divergence(base: String, head: String, in directory: String) async -> GitRefDivergence? { nil }
    func blobContent(revision: String, path: String, in directory: String) async -> String? { nil }
    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata] { [:] }
    func commitDetail(hash: String, in directory: String) async -> GitCommitDetail? { nil }
    func createBranch(_ branch: String, fromRev rev: String, in directory: String) async throws {
        // 写操作的默认实现必须显式抛错(同下方 stash/删分支):空 `{}` 会让忘实现的
        // 测试替身在"建分支"上假成功,掩盖真实的未实现状态。
        throw GitServiceError.operationFailed(message: "当前实现不支持创建分支")
    }
    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持基于远端分支创建")
    }
    func gitEnvironmentInfo() async -> GitEnvironmentInfo {
        GitEnvironmentInfo(isAvailable: false, version: nil, executablePath: nil)
    }
    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }
    func stashList(in directory: String) async -> [GitStashEntry] { [] }
    /// 默认实现委托旧接口:测试替身无需感知结果令牌语义即可编译;
    /// 生产 GitService 覆写为可判别"是否真的创建了暂存"的 SHA 追踪版本。
    func trackedStashCreate(in directory: String) async throws -> GitTrackedStash {
        try await stash(in: directory)
        return .created(sha: nil)
    }
    func trackedStashRestore(sha trackedStash: GitTrackedStash, in directory: String) async throws {
        // 默认实现维持"弹栈顶";`.notCreated` 只可能由真实实现的空转检测产出,
        // 防御性按空操作处理(弹走用户既有 stash 的后果是数据错乱级)。
        if case .notCreated = trackedStash { return }
        try await stashPop(in: directory)
    }
    // 破坏性操作的默认实现必须显式抛错:此前是空 `{}`,忘实现的测试替身在
    // "丢弃改动/提交/删分支"上会假成功,掩盖真实的未实现状态。
    func stashPush(in directory: String, message: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持暂存改动")
    }
    func popStash(at index: Int, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持恢复指定暂存")
    }
    func dropStash(at index: Int, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持删除暂存")
    }
    func discardChanges(filePath: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持丢弃改动")
    }
    func commitAllChanges(message: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持提交改动")
    }
    func deleteLocalBranch(_ branch: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持删除本地分支")
    }
    func deleteRemoteBranch(_ branch: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持删除远端分支")
    }
    func abortInterruptedOperation(in directory: String) async throws -> GitInterruptedOperation {
        throw GitServiceError.operationFailed(message: "当前实现不支持中止操作")
    }
    // rev 版本默认实现回退到 HEAD 查询:便于测试替身只实现旧方法即可编译;
    // 真实 GitService 覆写这两个方法,按 rev 查询。
    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        await recentCommits(in: directory, count: count)
    }
    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        await unpushedCommits(in: directory, count: count)
    }
    /// 测试替身回退通道:按 skip/count 切片既有全量查询,**不做关键词过滤**
    /// (桩里没有可搜的历史)。真实 GitService 覆写本方法并把搜索下推到 git;
    /// 搜索语义的用例请对 GitService 跑真实仓库。
    func commitLogPage(_ request: CommitLogPageRequest) async -> GitCommitLogPage {
        let headCount = max(0, request.skip) + max(1, request.count) + 1
        let fetched: [GitCommitEntry]
        if request.unpushedOnly {
            fetched = await unpushedCommits(in: request.directory, count: headCount, rev: request.rev)
        } else {
            fetched = await recentCommits(in: request.directory, count: headCount, rev: request.rev)
        }
        let page = Array(fetched.dropFirst(max(0, request.skip)).prefix(max(1, request.count)))
        return GitCommitLogPage(commits: page, hasMore: fetched.count > max(0, request.skip) + max(1, request.count))
    }
    func probeRemoteInfo(for remoteURL: String) async -> (branches: [String], defaultBranch: String?) {
        async let branchesTask = remoteBranches(for: remoteURL)
        async let defaultBranchTask = defaultBranch(for: remoteURL)
        return await (branchesTask ?? [], defaultBranchTask)
    }
}

extension GitServicing {
    func branchSnapshotInfo(in directory: String) async -> BranchSnapshotInfo? {
        let status = await branchStatus(in: directory)
        let currentBranch: String?
        if let statusBranch = status?.currentBranch {
            currentBranch = statusBranch
        } else {
            currentBranch = await self.currentBranch(in: directory)
        }
        guard currentBranch != nil || status != nil else { return nil }
        let branchList = await branches(in: directory)
        return BranchSnapshotInfo(
            currentBranch: currentBranch,
            branches: branchList,
            status: status ?? GitBranchStatusSnapshot(
                currentBranch: currentBranch,
                hasRemoteTrackingBranch: false,
                hasUncommittedChanges: false
            )
        )
    }

    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome {
        try await pull(in: directory)
        let current = await currentBranch(in: directory)
        return GitPullAllBranchesOutcome(
            currentBranch: current,
            currentBranchOutcome: current.map {
                GitBranchPullOutcome(branch: $0, status: .pulled, errorMessage: nil)
            },
            otherBranchOutcomes: [],
            primaryError: nil
        )
    }
}

struct GitCommitEntry: Identifiable, Equatable {
    let hash: String
    let subject: String
    let author: String
    let date: Date
    var filesChanged: Int? = nil
    var insertions: Int? = nil
    var deletions: Int? = nil

    var id: String { hash }

    var shortHash: String {
        String(hash.prefix(7))
    }

    /// 是否包含变更统计(用于 UI 决定是否展示统计行)。
    var hasStats: Bool { filesChanged != nil }
}

/// 提交记录窗口的分页查询参数。
struct CommitLogPageRequest: Equatable {
    let directory: String
    /// 搜索关键词;`nil` 或归一后为空表示不过滤。非空时过滤下推到 git,
    /// 命中范围是整条提交说明(标题+正文)、作者,以及形如 object ID 的关键词。
    let searchText: String?
    /// 结果级偏移(`--skip`),即上一页之前的命中数/已加载条数。
    let skip: Int
    /// 页大小;内部多取一条探测是否还有更多。
    let count: Int
    let rev: String?
    let unpushedOnly: Bool
}

/// 一页提交记录 + 是否还有下一页。
struct GitCommitLogPage: Equatable {
    let commits: [GitCommitEntry]
    let hasMore: Bool

    static let empty = GitCommitLogPage(commits: [], hasMore: false)
}

/// 单个提交的完整详情(`git show -s` 按需取,不进列表日志格式,避免多行正文破坏行解析)。
struct GitCommitDetail: Equatable, Sendable {
    let hash: String
    let authorName: String
    let authorEmail: String
    let date: Date?
    /// 完整提交信息(标题 + 正文)。
    let fullMessage: String

    /// 解析 `git show -s --format=%H%1F%an%1F%ae%1F%aI%1F%B <hash>` 的输出(%B 在最后,自身可含换行)。
    static func parseShow(_ output: String) -> GitCommitDetail? {
        let fields = output.components(separatedBy: "\u{01}")
        guard fields.count == 5 else { return nil }
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
        return GitCommitDetail(
            hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
            authorEmail: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
            date: iso8601.date(from: fields[3].trimmingCharacters(in: .whitespacesAndNewlines)),
            fullMessage: fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// 一条 Stash记录(`git stash list` 中的一行)。
struct GitStashEntry: Identifiable, Equatable, Sendable {
    /// stash 栈位置(stash@{index}),0 为最新。
    let index: Int
    /// Stash 消息(`git stash push -m` 或自动生成的 WIP 消息)。
    let message: String
    let date: Date

    var id: Int { index }
    var ref: String { "stash@{\(index)}" }

    /// 解析 `git stash list --format=%gs\u{1F}%cI` 输出;行序即栈位置。
    static func parseList(_ output: String) -> [GitStashEntry] {
        let fieldSeparator = "\u{1F}"
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        return output.components(separatedBy: .newlines).enumerated().compactMap { lineIndex, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let parts = trimmed.components(separatedBy: fieldSeparator)
            // 消息本身可能含 \u{1F}(stash push -m 手工构造):此前 `count == 2` 硬性
            // 丢弃该行,行序即栈位置,丢一行会让其后所有条目的 index 前移——
            // popStash/dropStash 按 index 操作会命中错误的 stash(drop 不可恢复)。
            // 改为 `count >= 2`:前 n-1 段重建完整消息,日期恒取末段,行永不丢。
            guard parts.count >= 2 else { return nil }
            return GitStashEntry(
                index: lineIndex,
                message: parts.dropLast().joined(separator: fieldSeparator),
                date: dateFormatter.date(from: parts[parts.count - 1]) ?? .distantPast
            )
        }
    }
}

/// 一个文件的 diff 内容。
struct GitDiffEntry: Identifiable, Equatable {
    /// 变更后的文件路径(`git diff --numstat` 的第三列)。
    let filePath: String
    /// 新增行数;-1 表示二进制文件。
    let insertions: Int
    /// 删除行数;-1 表示二进制文件。
    let deletions: Int
    /// 该文件的完整 unified diff 文本(含 `diff --git` / `@@` / `+` / `-` 行)。
    let patch: String

    /// 身份标识:只用 filePath 不够——`git diff -M` 输出重命名时 numstat 的第三列
    /// 可能是 `a/{old => new}` 形式,两个条目会撞 id,导致 ForEach 与按 id 索引的
    /// 展开状态串号。拼上 patch 的散列保证同批次内唯一。
    var id: String { "\(filePath)#\(patch.hashValue)" }

    var isBinary: Bool { insertions < 0 || deletions < 0 }

    /// 变更类型(用于 UI 图标/着色)。
    var changeType: GitDiffChangeType {
        // `new file mode` / `deleted file mode` / `rename from` 只出现在 diff header 区域,
        // 不应匹配文件内容中恰好包含这些词的行,因此只检查 patch 的前 5 行。
        let headerLines = patch.components(separatedBy: .newlines).prefix(5).joined(separator: "\n")
        if headerLines.contains("new file mode") { return .added }
        if headerLines.contains("deleted file mode") { return .deleted }
        if headerLines.contains("rename from") || headerLines.contains("rename to") { return .renamed }
        return .modified
    }

    /// 仅展示文件名(去掉目录前缀)。
    var fileName: String {
        (filePath as NSString).lastPathComponent
    }
}

enum GitDiffChangeType: Equatable {
    case modified
    case added
    case deleted
    case renamed
}

/// 两个 ref 的分歧提交数(`git rev-list --left-right --count base...head`)。
struct GitRefDivergence: Equatable, Sendable {
    /// 仅存在于 base 侧的提交数(head 相对 base 缺这些)。
    let baseOnlyCount: Int
    /// 仅存在于 head 侧的提交数(base 相对 head 缺这些)。
    let headOnlyCount: Int

    /// 解析 "L\tR" 输出;格式不符(异常仓库/非法 ref)返回 nil。
    static func parse(_ output: String) -> GitRefDivergence? {
        let tokens = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .map(String.init)
        guard tokens.count == 2,
              let left = Int(tokens[0]),
              let right = Int(tokens[1]) else {
            return nil
        }
        return GitRefDivergence(baseOnlyCount: left, headOnlyCount: right)
    }
}

/// git 环境检测结果(设置页诊断展示用)。
struct GitEnvironmentInfo: Equatable, Sendable {
    /// `git --version` 可正常执行。
    let isAvailable: Bool
    /// `git --version` 输出原文,如 "git version 2.39.5 (Apple Git-150)"。
    let version: String?
    /// 探测到的 git 可执行文件路径,如 "/usr/bin/git";未找到任何候选时为 nil。
    let executablePath: String?
}

enum GitMergeDefaultBranchOutcome: Equatable {
    case merged
    case skipped
}

struct GitBranchPullOutcome: Sendable {
    enum Status: Sendable, Equatable {
        case pulled
        case alreadyUpToDate
        case skippedDiverged
        case skippedNoUpstream
        /// 分支已被其它 worktree 检出,本地 fetch 被 git 拒绝——这不是故障,
        /// 归入跳过类,避免每轮批量拉取都给用户一个误导性的"失败"。
        case skippedCheckedOutElsewhere
        case failed
    }
    let branch: String
    let status: Status
    let errorMessage: String?
}

struct GitPullAllBranchesOutcome: Sendable {
    let currentBranch: String?
    let currentBranchOutcome: GitBranchPullOutcome?
    let otherBranchOutcomes: [GitBranchPullOutcome]
    let primaryError: (any Error & Sendable)?
}

struct BranchSnapshotInfo: Equatable, Sendable {
    let currentBranch: String?
    let branches: [String]
    let status: GitBranchStatusSnapshot
}

struct GitBranchStatusSnapshot: Equatable {
    let currentBranch: String?
    let hasRemoteTrackingBranch: Bool
    let hasUncommittedChanges: Bool
    /// 相对 upstream(远程跟踪分支)领先的提交数，即未推送提交数；无 upstream 时为 0。
    let aheadCount: Int
    /// 相对 upstream 落后的提交数，即远端已有而本地未合入的提交数；无 upstream 时为 0。
    let behindCount: Int
    /// 处于未合并(冲突)状态的文件路径(仓库相对路径),来自 porcelain v2 的 `u` 行。
    let unmergedPaths: [String]
    /// 进行中的可中止操作(合并/变基等)。porcelain 输出不含该信息,
    /// 由快照加载在检测到冲突后探测 git 目录标记文件填充;无冲突或未探测时为 nil。
    var interruptedOperation: GitInterruptedOperation?

    var hasUnpushedCommits: Bool { aheadCount > 0 }
    var isBehindRemote: Bool { behindCount > 0 }
    var hasConflicts: Bool { unmergedPaths.isEmpty == false }
    var conflictCount: Int { unmergedPaths.count }

    var isClean: Bool {
        hasUncommittedChanges == false &&
        hasUnpushedCommits == false &&
        isBehindRemote == false &&
        hasRemoteTrackingBranch
    }

    init(
        currentBranch: String?,
        hasRemoteTrackingBranch: Bool,
        hasUncommittedChanges: Bool,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        unmergedPaths: [String] = [],
        interruptedOperation: GitInterruptedOperation? = nil
    ) {
        self.currentBranch = currentBranch
        self.hasRemoteTrackingBranch = hasRemoteTrackingBranch
        self.hasUncommittedChanges = hasUncommittedChanges
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.unmergedPaths = unmergedPaths
        self.interruptedOperation = interruptedOperation
    }

    static func parsePorcelainV2(_ output: String) -> GitBranchStatusSnapshot {
        var currentBranch: String?
        var hasRemoteTrackingBranch = false
        var aheadCount = 0
        var behindCount = 0
        var hasUncommittedChanges = false
        var unmergedPaths: [String] = []

        for rawLine in output.components(separatedBy: .newlines) {
            // 路径可能含首尾空格,`u` 行必须用未 trim 的原始行解析,
            // 其余行沿用去空白语义。
            if rawLine.hasPrefix("u ") {
                hasUncommittedChanges = true
                if let path = unmergedPath(fromLine: rawLine) {
                    unmergedPaths.append(path)
                }
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }

            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                if value != "(detached)" {
                    currentBranch = value
                }
                continue
            }

            if line.hasPrefix("# branch.upstream ") {
                hasRemoteTrackingBranch = true
                continue
            }

            if line.hasPrefix("# branch.ab ") {
                let components = line
                    .dropFirst("# branch.ab ".count)
                    .split(separator: " ")
                for component in components {
                    if component.hasPrefix("+") {
                        aheadCount = Int(component.dropFirst()) ?? 0
                    } else if component.hasPrefix("-") {
                        behindCount = Int(component.dropFirst()) ?? 0
                    }
                }
                continue
            }

            if line.hasPrefix("#") == false {
                hasUncommittedChanges = true
            }
        }

        return GitBranchStatusSnapshot(
            currentBranch: currentBranch,
            hasRemoteTrackingBranch: hasRemoteTrackingBranch,
            hasUncommittedChanges: hasUncommittedChanges,
            aheadCount: aheadCount,
            behindCount: behindCount,
            unmergedPaths: unmergedPaths
        )
    }

    /// 解析 porcelain v2 未合并(`u`)行的文件路径。
    /// 实测行格式(git 2.39): `u <XY> <sub> <mode>×4 <hash>×3 <path>[\t<origPath>]`,
    /// 前 10 个字段不含空格,路径是剩余全部内容(自身可含空格),rename 冲突时原路径以 tab 缀后。
    static func unmergedPath(fromLine line: String) -> String? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11, fields[0] == "u" else { return nil }
        let rawPath = String(fields[10]).components(separatedBy: "\t").first ?? ""
        let path = decodePorcelainPath(rawPath)
        return path.isEmpty ? nil : path
    }

    /// 解码 porcelain 路径:git 对含特殊字符(引号、控制符、非 ASCII 且 core.quotepath)
    /// 的路径做 C 风格引用(`"..."` + 八进制/转义序列),普通路径原样返回。
    static func decodePorcelainPath(_ rawPath: String) -> String {
        guard rawPath.hasPrefix("\""), rawPath.hasSuffix("\""), rawPath.count >= 2 else {
            return rawPath
        }
        let body = rawPath.dropFirst().dropLast()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count)
        // 索引推进而非迭代器:八进制转义提前结束(不足 3 位、后继非八进制数字)时,
        // 终止字符不能被消耗后丢弃——迭代器版的 `let next = iterator.next()`
        // 会把非数字的合法后继字符吞掉。git 恒输出 3 位八进制,此为防御性正确。
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                continue
            }
            guard index < body.endIndex else {
                // 结尾裸反斜杠:按字面量保留,不丢内容。
                bytes.append(UInt8(ascii: "\\"))
                continue
            }
            let escaped = body[index]
            index = body.index(after: index)
            switch escaped {
            case "\"": bytes.append(UInt8(ascii: "\""))
            case "\\": bytes.append(UInt8(ascii: "\\"))
            case "a": bytes.append(UInt8(ascii: "\u{07}"))
            case "b": bytes.append(UInt8(ascii: "\u{08}"))
            case "f": bytes.append(UInt8(ascii: "\u{0C}"))
            case "n": bytes.append(UInt8(ascii: "\n"))
            case "r": bytes.append(UInt8(ascii: "\r"))
            case "t": bytes.append(UInt8(ascii: "\t"))
            case "v": bytes.append(UInt8(ascii: "\u{0B}"))
            case let digit where ("0"..."9").contains(digit):
                // 八进制 \NNN(N 最多 3 位)。数字判定用 ASCII 范围而非 Unicode
                // isNumber:非 ASCII 数字不是合法八进制位(本文件另一处注释
                // 已声明此约定),误判会把转义序列拼坏。
                var digits = String(digit)
                while digits.count < 3, index < body.endIndex, ("0"..."9").contains(body[index]) {
                    digits.append(body[index])
                    index = body.index(after: index)
                }
                if let value = UInt8(digits, radix: 8) {
                    bytes.append(value)
                } else {
                    bytes.append(contentsOf: "\\\(digits)".utf8)
                }
            default:
                bytes.append(contentsOf: "\\\(escaped)".utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Git 处于"进行中、可中止"状态的操作。冲突几乎只发生在这些操作中途,
/// 冲突 popover 的"中止"入口据此选择具体命令与文案。
enum GitInterruptedOperation: String, CaseIterable, Codable, Equatable, Sendable {
    case rebase
    case cherryPick
    case revert
    case merge
    case bisect

    /// 面向用户的中文名称,用于"中止合并"等文案。
    var displayName: String {
        switch self {
        case .rebase: return "变基"
        case .cherryPick: return "Cherry Pick"
        case .revert: return "Revert"
        case .merge: return "合并"
        case .bisect: return "二分定位"
        }
    }

    /// git 目录中标识该操作进行中的标记文件/目录。
    var markerNames: [String] {
        switch self {
        case .rebase: return ["rebase-merge", "rebase-apply"]
        case .cherryPick: return ["CHERRY_PICK_HEAD"]
        case .revert: return ["REVERT_HEAD"]
        case .merge: return ["MERGE_HEAD"]
        case .bisect: return ["BISECT_LOG"]
        }
    }

    /// 中止该操作的 git 子命令参数。
    var abortArguments: [String] {
        switch self {
        case .rebase: return ["rebase", "--abort"]
        case .cherryPick: return ["cherry-pick", "--abort"]
        case .revert: return ["revert", "--abort"]
        case .merge: return ["merge", "--abort"]
        case .bisect: return ["bisect", "reset"]
        }
    }

    /// allCases 顺序即探测优先级:cherry-pick/revert 会同时留下各自的 HEAD 标记与
    /// MERGE_HEAD,变基过程内部也复用 merge 机制,因此 merge 的标记必须最后匹配。
    static func detect(
        gitDirectoryPath: String,
        itemExists: (String) -> Bool
    ) -> GitInterruptedOperation? {
        for operation in allCases {
            let matched = operation.markerNames.contains { name in
                itemExists("\(gitDirectoryPath)/\(name)")
            }
            if matched { return operation }
        }
        return nil
    }
}

/// 单个本地分支的元数据(for-each-ref 一次扫描得到):最后提交时间与相对上游的领先/落后。
/// 供分支面板行内展示"⇡1 ⇣3 · 3 天前"并按最近活动排序。
struct GitBranchMetadata: Equatable, Sendable {
    let lastCommitDate: Date?
    let aheadCount: Int
    let behindCount: Int
    /// 上游已被删除(git 标记 [gone])。
    let upstreamGone: Bool
    /// 是否配置了上游跟踪分支(`%(upstream)` 非空)。
    /// 不能用 track 是否为空判断:有上游且同步时 track 同样是空串。
    let hasUpstream: Bool

    init(
        lastCommitDate: Date?,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        upstreamGone: Bool = false,
        hasUpstream: Bool = false
    ) {
        self.lastCommitDate = lastCommitDate
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.upstreamGone = upstreamGone
        self.hasUpstream = hasUpstream
    }

    /// 解析 `git for-each-ref --format='%(refname:short)%01%(committerdate:unix)%01%(upstream:track)%01%(upstream)' refs/heads`。
    static func parseForEachRef(_ output: String) -> [String: GitBranchMetadata] {
        var result: [String: GitBranchMetadata] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "\u{01}")
            guard fields.count == 4 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            guard name.isEmpty == false else { continue }
            let timestamp = Int64(fields[1].trimmingCharacters(in: .whitespaces))
            let track = parseUpstreamTrack(fields[2])
            result[name] = GitBranchMetadata(
                lastCommitDate: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                aheadCount: track.ahead,
                behindCount: track.behind,
                upstreamGone: track.gone,
                hasUpstream: fields[3].trimmingCharacters(in: .whitespaces).isEmpty == false
            )
        }
        return result
    }

    /// 解析 upstream:track 字段:`[ahead 1, behind 2]` / `[ahead 3]` / `[behind 5]` / `[gone]` / 空。
    static func parseUpstreamTrack(_ raw: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let body = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard body.isEmpty == false else { return (0, 0, false) }
        var ahead = 0
        var behind = 0
        var gone = false
        for part in body.components(separatedBy: ",") {
            let tokens = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            switch (tokens.first.map(String.init), tokens.count > 1 ? Int(tokens[1]) : nil) {
            case ("ahead", let count?): ahead = count
            case ("behind", let count?): behind = count
            case ("gone", _): gone = true
            default: break
            }
        }
        return (ahead, behind, gone)
    }
}

enum GitWorktreeBlockedOperation: Equatable, Sendable {
    case switchBranch
    case mergeDefaultBranchIntoCurrent
}

enum GitWorktreeSafetyError: LocalizedError, Equatable, Sendable {
    case unreadableStatus
    case uncommittedChanges(blockedOperation: GitWorktreeBlockedOperation)
    case stashRestoreFailed(reason: String)
    case operationAndStashRestoreFailed(operationReason: String, restoreReason: String)

    var errorDescription: String? {
        switch self {
        case .unreadableStatus:
            return "无法读取仓库 Git 状态"
        case .uncommittedChanges(let blockedOperation):
            switch blockedOperation {
            case .switchBranch:
                return "仓库有未提交的改动，无法切换分支"
            case .mergeDefaultBranchIntoCurrent:
                return "仓库有未提交的改动，无法合并默认分支"
            }
        case .stashRestoreFailed(let reason):
            return "操作已完成，但恢复临时保存的本地改动失败：\(reason)"
        case .operationAndStashRestoreFailed(let operationReason, let restoreReason):
            return "操作失败：\(operationReason)。同时恢复临时保存的本地改动失败：\(restoreReason)"
        }
    }
}

enum GitWorktreeSafety {
    static func validateCleanWorkingTree(
        in directory: String,
        gitService: GitServicing,
        blockedOperation: GitWorktreeBlockedOperation
    ) async throws {
        guard let branchStatus = await gitService.branchStatus(in: directory) else {
            throw GitWorktreeSafetyError.unreadableStatus
        }
        guard branchStatus.hasUncommittedChanges == false else {
            throw GitWorktreeSafetyError.uncommittedChanges(blockedOperation: blockedOperation)
        }
    }

    static func withCleanWorkingTree(
        in directory: String,
        gitService: GitServicing,
        blockedOperation: GitWorktreeBlockedOperation,
        body: @Sendable () async throws -> Void
    ) async throws {
        // 记录自动暂存的结果令牌:body 内含 fetch/merge 等可达 60s 的联网操作,
        // 窗口期内用户或其它任务的 `git stash` 会让"弹栈顶"(stash@{0})弹到**别人的
        // stash**——错内容进工作区、真目标滞留栈里,属数据错乱级后果。
        var trackedStash: GitTrackedStash?
        do {
            try await validateCleanWorkingTree(
                in: directory,
                gitService: gitService,
                blockedOperation: blockedOperation
            )
        } catch GitWorktreeSafetyError.uncommittedChanges {
            let token = try await gitService.trackedStashCreate(in: directory)
            // notCreated:push 因竞态空转("No local changes to save" 但退出码 0)。
            // 此时栈里的条目(若有)全是用户既有 stash,绝不能进入恢复路径。
            if token != .notCreated {
                trackedStash = token
            }
        }

        do {
            try await body()
        } catch let operationError {
            if let trackedStash {
                do {
                    try await restoreStash(token: trackedStash, in: directory, gitService: gitService)
                } catch let restoreError {
                    throw GitWorktreeSafetyError.operationAndStashRestoreFailed(
                        operationReason: UserFacingError.message(for: operationError),
                        restoreReason: UserFacingError.message(for: restoreError)
                    )
                }
            }
            throw operationError
        }

        if let trackedStash {
            do {
                try await restoreStash(token: trackedStash, in: directory, gitService: gitService)
            } catch {
                throw GitWorktreeSafetyError.stashRestoreFailed(
                    reason: UserFacingError.message(for: error)
                )
            }
        }
    }

    /// 恢复自动暂存必须**脱离当前取消上下文**执行。
    ///
    /// body 内含 fetch/merge 等可达 60s 的联网操作,View 在 `onDisappear` 会 cancel
    /// 任务——此时恢复动作若仍在该已取消的任务里跑,`GitProcessRunner` 开头的
    /// `Task.checkCancellation()` 会直接拒绝,暂存永远回不到工作区。
    /// detached 任务不继承取消,恢复照常完成;body 的取消原样由调用方上抛。
    private static func restoreStash(
        token: GitTrackedStash,
        in directory: String,
        gitService: GitServicing
    ) async throws {
        let service = gitService
        try await Task.detached(priority: .userInitiated) {
            try await service.trackedStashRestore(sha: token, in: directory)
        }.value
    }
}

/// 进程级"remote URL → 默认分支"缓存:本地无 origin/HEAD 时 defaultBranch 会回退
/// `ls-remote --symref` 联网探测,批量合并前每仓库查一次会串行叠加数秒网络延迟;
/// 同一远端的默认分支在一次进程运行内几乎不会变,查得一次后直接复用。
/// 只缓存成功结果(nil 多为瞬时网络失败,下次仍应重试)。
///
/// 失效策略:pull/fetch 等本地写操作成功后**整体清空**。fetch/pull 发生在本地仓库,
/// 要按 remote 精确失效得再跑一次 `remote get-url` 反查——不值得为此新增进程调用;
/// 缓存量小(每远端一条),整体清空最多让下次探测多走一次 ls-remote,语义安全。
private final class RemoteDefaultBranchCache: @unchecked Sendable {
    static let shared = RemoteDefaultBranchCache()

    private let lock = NSLock()
    private var branchesByRemoteURL: [String: String] = [:]

    /// 缓存键统一 trim:调用方有的先 trim(MergeRequestService)有的没有,
    /// 键不一致会让同一远端反复走 ls-remote。
    private static func cacheKey(for remoteURL: String) -> String {
        remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func branch(for remoteURL: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return branchesByRemoteURL[Self.cacheKey(for: remoteURL)]
    }

    func store(_ branch: String, for remoteURL: String) {
        lock.lock()
        defer { lock.unlock() }
        branchesByRemoteURL[Self.cacheKey(for: remoteURL)] = branch
    }

    /// 清空全部缓存条目;远端状态可能发生变化的写操作成功后调用。
    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        branchesByRemoteURL.removeAll()
    }
}

extension GitService {
    /// 仅测试用:清空进程级默认分支缓存,避免用例之间通过缓存串扰。
    static func resetForTesting() {
        RemoteDefaultBranchCache.shared.invalidateAll()
    }
}

struct GitService: GitServicing {
    /// 仅测试用：注入到每个 git 子进程的额外环境变量（配置隔离，如
    /// `GIT_CONFIG_GLOBAL`）。生产路径恒为 `[:]`，行为零变化；
    /// 默认值保证 `GitService()` 这样的既有构造不受影响。
    var additionalEnvironment: [String: String] = [:]

    // 8 路并发 `fetch .` 会争抢同一仓库的 packed-refs/index 锁,失败率不降反升;
    // 4 路是吞吐与锁竞争的平衡点。
    private static let maxConcurrentBranchFfTasks = 4

    func clone(repositoryURL: String, into directory: String) async throws {
        try GitURLParser.validateRemoteURL(repositoryURL)
        let directoryExistedBefore = FileManager.default.fileExists(atPath: directory)
        do {
            try await runGit(arguments: ["clone", "--", repositoryURL, directory], timeout: 600)
        } catch {
            // 超时 SIGKILL/取消/网络失败会留下"半克隆"目录:hasLocalDirectory=false 让
            // pull 阶段跳过它,重新 clone 又因"目标目录已存在"永远失败——无自愈路径的死局。
            // 仅清理"本次调用前不存在"的目录,绝不误删用户既有内容。
            // 递归删除移出主线程:半克隆可达数 GB,主线程 rm -rf 会冻结 UI。
            // TOCTOU 复核:上面的判定是克隆开始前的时点快照,窗口期内该路径可能被
            // 外部进程创建,删除前再确认它确属本次半克隆产物(见 isPartialCloneRemnant)。
            if directoryExistedBefore == false,
               Self.isPartialCloneRemnant(at: directory) {
                let path = directory
                await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(atPath: path)
                }.value
            }
            throw error
        }
    }

    /// 失败后的目标目录是否为"本次半克隆的残留",可安全删除。
    ///
    /// git clone 先初始化 `.git` 再 fetch,失败残留必含 `.git`;仅剩空目录是
    /// "建目录后、写 .git 前被杀"的极端窗口。非空且无 `.git` 的目录不认领——
    /// 那多半是窗口期内外部进程放进来的内容,宁可留下残目录也不删用户数据。
    ///
    /// 标记为 internal(而非 private)纯粹是为了单测能直接覆盖三种形态;
    /// 生产调用方只有 `clone` 的失败清理路径。
    static func isPartialCloneRemnant(at directory: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        return entries.isEmpty || entries.contains(".git")
    }

    func pull(in directory: String) async throws {
        do {
            try await runGit(arguments: ["-C", directory, "pull"])
        } catch let error as GitServiceError where Self.isMissingPullStrategyError(error) {
            // git 2.34+ 在分叉且未配置 pull.rebase/pull.ff 时拒绝 pull,这里回退为显式合并。
            try await runGit(arguments: ["-C", directory, "pull", "--no-rebase"])
        }
        // pull 成功说明远端状态可能已变化,失效默认分支缓存(见 RemoteDefaultBranchCache 注释)。
        RemoteDefaultBranchCache.shared.invalidateAll()
    }

    /// git 拒绝 pull 是否因为「分叉且未配置合并策略」。
    private static func isMissingPullStrategyError(_ error: GitServiceError) -> Bool {
        error.stderr.lowercased().contains("reconcile divergent branches")
    }

    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome {
        try await runGit(arguments: ["-C", directory, "fetch", "origin"])
        // fetch 成功:远端引用已刷新,失效默认分支缓存(粗粒度整体清空,取舍见缓存注释)。
        RemoteDefaultBranchCache.shared.invalidateAll()
        let current = await currentBranch(in: directory)

        var currentBranchOutcome: GitBranchPullOutcome?
        var primaryError: (any Error & Sendable)?

        if let current {
            do {
                try await pull(in: directory)
                currentBranchOutcome = GitBranchPullOutcome(branch: current, status: .pulled, errorMessage: nil)
            } catch let e as GitServiceError {
                // per-branch 的 errorMessage 会被 Views 直接拼成「<branch> 失败：<msg>」,
                // 必须和 primaryError 一样走 UserFacingError,否则英文原文原样进 UI。
                currentBranchOutcome = GitBranchPullOutcome(
                    branch: current,
                    status: .failed,
                    errorMessage: UserFacingError.message(for: e)
                )
                primaryError = e
            }
        }

        let allBranchesOutput: String
        do {
            allBranchesOutput = try await runGitOutput(arguments: [
                "-C", directory,
                "for-each-ref",
                "--format=%(refname:short)",
                "refs/heads",
            ])
        } catch {
            // 枚举分支失败时其余分支根本不会被拉取。若不记进 primaryError,
            // 上层会以为"全部成功",实际只拉了当前分支。
            allBranchesOutput = ""
            if primaryError == nil {
                primaryError = error
            }
        }
        let allBranches = allBranchesOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var others: [GitBranchPullOutcome] = []
        let otherBranches = allBranches.filter { $0 != current }
        if !otherBranches.isEmpty {
            others = try await withThrowingTaskGroup(
                of: GitBranchPullOutcome.self
            ) { group in
                let taskCount = min(Self.maxConcurrentBranchFfTasks, otherBranches.count)
                var nextIndex = 0
                for _ in 0..<taskCount {
                    let branch = otherBranches[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await self.fastForwardBranchIfPossible(branch, in: directory)
                    }
                }

                var results: [GitBranchPullOutcome] = []
                while let outcome = try await group.next() {
                    results.append(outcome)
                    guard nextIndex < otherBranches.count else { continue }
                    let branch = otherBranches[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await self.fastForwardBranchIfPossible(branch, in: directory)
                    }
                }
                return results
            }
        }

        return GitPullAllBranchesOutcome(
            currentBranch: current,
            currentBranchOutcome: currentBranchOutcome,
            otherBranchOutcomes: others,
            primaryError: primaryError
        )
    }

    private func fastForwardBranchIfPossible(
        _ branch: String,
        in directory: String
    ) async throws -> GitBranchPullOutcome {
        let upstreamOutput: String
        do {
            upstreamOutput = try await runGitOutput(arguments: [
                "-C", directory,
                "for-each-ref",
                "--format=%(upstream:short)",
                "refs/heads/\(branch)",
            ])
        } catch is CancellationError {
            // 取消不能折算成 .failed 假失败:原样上抛,让任务组整体传播取消。
            throw CancellationError()
        } catch {
            return GitBranchPullOutcome(
                branch: branch,
                status: .failed,
                errorMessage: UserFacingError.message(for: error)
            )
        }
        let upstream = upstreamOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard upstream.isEmpty == false else {
            return GitBranchPullOutcome(branch: branch, status: .skippedNoUpstream, errorMessage: nil)
        }

        // merge-base --is-ancestor: exit 0 = 是祖先, exit 1 = 不是, 其他 = 错误
        // runRawGit 会把取消原样抛出,由任务组传播。
        let isAncestorResult = try await runRawGit(
            arguments: ["-C", directory, "merge-base", "--is-ancestor", "refs/heads/\(branch)", "refs/remotes/\(upstream)"]
        )
        switch isAncestorResult {
        case .exited(0):
            let localSHA: String
            let remoteSHA: String
            do {
                // rev-parse 失败不能吞成空串:空 SHA 会被误判为"不等"而走 fetch 路径,
                // 真实原因(引用损坏等)彻底丢失。这里区分失败与"已同步"。
                localSHA = try await runGitOutput(arguments: ["-C", directory, "rev-parse", "refs/heads/\(branch)"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                remoteSHA = try await runGitOutput(arguments: ["-C", directory, "rev-parse", "refs/remotes/\(upstream)"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return GitBranchPullOutcome(
                    branch: branch,
                    status: .failed,
                    errorMessage: UserFacingError.message(for: error)
                )
            }
            if !localSHA.isEmpty && localSHA == remoteSHA {
                return GitBranchPullOutcome(branch: branch, status: .alreadyUpToDate, errorMessage: nil)
            }
            do {
                // 用本地仓库作为 fetch 源做纯 fast-forward 更新(不联网):
                // 非快进会被 git 拒绝,分支被任意 worktree checkout 时同样拒绝,
                // 比直接 update-ref 更安全(不会让其他 worktree 的文件与引用脱节)。
                try await runGit(arguments: [
                    "-C", directory,
                    "fetch", ".",
                    "refs/remotes/\(upstream):refs/heads/\(branch)",
                ])
                return GitBranchPullOutcome(branch: branch, status: .pulled, errorMessage: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitServiceError where Self.isWorktreeCheckedOutError(error) {
                return GitBranchPullOutcome(branch: branch, status: .skippedCheckedOutElsewhere, errorMessage: nil)
            } catch {
                return GitBranchPullOutcome(
                    branch: branch,
                    status: .failed,
                    errorMessage: UserFacingError.message(for: error)
                )
            }
        case .exited(1):
            return GitBranchPullOutcome(branch: branch, status: .skippedDiverged, errorMessage: nil)
        case .exited(let code):
            return GitBranchPullOutcome(branch: branch, status: .failed, errorMessage: "merge-base 退出码 \(code)")
        case .crashed(let message):
            return GitBranchPullOutcome(branch: branch, status: .failed, errorMessage: message)
        }
    }

    private enum RawGitResult: Sendable {
        case exited(Int32)
        case crashed(String)
    }

    private func runRawGit(arguments: [String], timeout: TimeInterval = 30) async throws -> RawGitResult {
        do {
            let result = try await runProcess(arguments: arguments, captureStdout: false, captureStderr: true, timeout: timeout)
            return .exited(result.terminationStatus)
        } catch is CancellationError {
            // 取消不能折算成 .crashed 假失败:原样上抛,让调用方/任务组感知取消。
            throw CancellationError()
        } catch {
            return .crashed(UserFacingError.message(for: error))
        }
    }

    func push(in directory: String) async throws {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }

        // 不用裸 `git push`:它会跟随用户全局 push.default,配 matching/all 时一次推出
        // 多个分支(或直接报错),行为随环境漂移。两条路径都显式指定 remote + 当前分支;
        // `--` 后的分支名由 git 优先解析为 ref(已实测:仓库内存在同名文件时仍推 ref),
        // 因此不会被当成 pathspec,同时挡住以 `-` 开头的分支名进选项位。
        if let upstream = await trackingBranch(in: directory) {
            // 上游形如 `<remote>/<branch>`;异常前缀(空、以 `-` 开头会被当选项)退回 origin。
            let prefix = upstream.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let remote = (prefix.isEmpty || prefix.hasPrefix("-")) ? "origin" : prefix
            try await runGit(arguments: ["-C", directory, "push", remote, "--", currentBranch])
            return
        }

        guard await remoteURL(in: directory) != nil else {
            throw gitOperationError("仓库未配置 origin 远端")
        }

        try await runGit(arguments: ["-C", directory, "push", "-u", "origin", "--", currentBranch])
    }

    func stash(in directory: String) async throws {
        try await stashPush(in: directory, message: "CCSpace temporary worktree safety stash")
    }

    func stashPop(in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "stash", "pop"])
    }

    /// 工作区 diff 里最多展示多少个未跟踪文件(超出部分不进 diff,但 `commitAllChanges`
    /// 的 `git add --all` 仍会提交它们——展示范围与提交范围不一致,必须由界面显式告知)。
    /// 放在 Service 侧作单一事实来源,视图引用它而不是各自抄一份数值。
    static let untrackedDisplayLimit = 100

    /// 按字面量解释的 pathspec。
    ///
    /// git 对 pathspec 默认启用 wildmatch:`test[1].txt` 是"匹配 test1.txt"的字符类,
    /// `a?b`/`*` 同理。文件名里出现这些字符是完全合法的(macOS/Linux 均可创建),
    /// 一旦进 `checkout`/`clean -f` 就会作用到**另一个**文件——`clean -f` 删掉的
    /// 未跟踪文件不可恢复。展示用路径与命令参数必须分离,命令侧一律加 `:(literal)`。
    static func literalPathspec(_ path: String) -> String { ":(literal)" + path }

    /// HEAD 等修订名解析不出来的失败特征(unborn HEAD 仓库下 `git diff HEAD` 的实测输出:
    /// "fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.")。
    /// 只有这类失败才值得用去掉修订名的命令重试。
    static func isUnresolvableRevisionError(_ error: Error) -> Bool {
        guard let gitError = error as? GitServiceError else { return false }
        let lower = gitError.stderr.lowercased()
        return lower.contains("unknown revision")
            || lower.contains("bad revision")
            || lower.contains("does not have any commits")
    }

    /// ASCII 十六进制的 object ID(可缩写):`Character.isHexDigit` 按 Unicode 取值会放行
    /// 阿拉伯-印度数字等非 ASCII 字符,与本仓库 ASCII-only 判定口径冲突(见 isCommitSHA)。
    static func isHexObjectID(_ candidate: String, minLength: Int = 7, maxLength: Int = 40) -> Bool {
        guard candidate.count >= minLength, candidate.count <= maxLength else { return false }
        return candidate.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character) || ("A"..."F").contains(character)
        }
    }

    /// 完整 commit SHA(40 位十六进制;未来 object format 也可能是 64 位)。
    static func isCommitSHA(_ candidate: String) -> Bool {
        // 只认 ASCII 十六进制:`Character.isHexDigit` 按 Unicode 取值,会放行阿拉伯-印度
        // 数字等非 ASCII 字符,与本仓库路径/计数列的 ASCII-only 判定口径
        // (见 GitDiffParser.isCountField)矛盾,也会削弱 createBranch(fromRev:) 与
        // blobContent(revision:) 的 ref 守卫。
        guard candidate.count == 40 || candidate.count == 64 else { return false }
        return candidate.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character) || ("A"..."F").contains(character)
        }
    }

    func trackedStashCreate(in directory: String) async throws -> GitTrackedStash {
        // `git stash push` 在无本地改动时打印 "No local changes to save" 但退出码 0
        // (状态检查与 push 之间存在竞态):push 前后各数一次栈内条目数对账,
        // 条目数未变即本次 push 空转——若不对账,记录到的是用户既有 stash 的 SHA,
        // 恢复侧见栈顶匹配会直接 pop 用户自己的 stash(数据破坏级)。
        // 对账口径用**条目数**而不是栈顶 SHA:SHA 口径下"空栈"与"查询失败"都是 nil,
        // push 前空栈 + push 后查询瞬败会双 nil 相等 → 误判 notCreated,
        // 用户改动静默滞留 stash 且操作报成功。
        let countBefore = try await trackedStashEntryCount(in: directory)
        try await stash(in: directory)
        // stash push 一旦成功,改动就已经进入 stash:此后的对账查询失败(进程级错误)
        // 或被取消,绝不能把错误上抛——上抛会让调用方按"操作失败/已取消"收场,
        // 而用户改动孤悬 stash、无任何恢复记录。降级为 created(sha: nil) 走无标识
        // 恢复(交恢复侧弹栈顶),与下方"查询失败返回 nil"的既有保守口径一致,
        // 不因追踪失败丢暂存。
        let countAfter: Int?
        do {
            countAfter = try await trackedStashEntryCount(in: directory)
        } catch {
            return .created(sha: nil)
        }
        // 计数查询失败(nil)时无法判"是否新建":保守按已新建处理(交恢复侧走 SHA /
        // 弹栈顶),绝不能折成 notCreated——那等于把刚暂存的改动留在栈里还报成功。
        let created = (countBefore == nil || countAfter == nil) ? true : (countAfter != countBefore)
        guard created else {
            return .notCreated
        }
        // rev-parse 异常(仓库竞态删除等)或被取消时 topAfter 拿不到:退回无标识恢复,
        // 与旧行为等价,不因追踪失败而丢暂存。
        let topAfter: String?
        do {
            topAfter = try await trackedStashTopSHA(in: directory)
        } catch {
            return .created(sha: nil)
        }
        return .created(sha: topAfter)
    }

    /// 当前 stash 栈的条目数(`git stash list` 行数)。
    ///
    /// 空栈时 git 也是退出码 0 + 空输出,只有 git 真实失败(非 0 退出,如目录不是仓库)
    /// 才返回 nil——"空栈(0)"与"查询失败(nil)"因此可区分,供 push 前后对账。
    /// 取消与进程级错误由 `outputIgnoringGitFailure` 原样上抛,不折算成 nil。
    private func trackedStashEntryCount(in directory: String) async throws -> Int? {
        guard let output = try await outputIgnoringGitFailure(arguments: [
            "-C", directory, "stash", "list", "--format=%H",
        ]) else {
            return nil
        }
        return output
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .count
    }

    /// 当前 stash 栈顶的 commit SHA;空栈(`rev-parse --verify -q` 退出码非 0)
    /// 或未取消的其它查询失败/输出异常返回 nil,供 push 前后对账判"是否新建了暂存"。
    private func trackedStashTopSHA(in directory: String) async throws -> String? {
        // 取消不能折算成"拿不到 SHA"(bf03e1c 语义):任务已取消时悄悄继续会失去
        // 原样传播,恢复侧还会在期间又 stash 的情况下弹错条目,故单独原样上抛。
        let sha: String?
        do {
            sha = try await outputIgnoringGitFailure(arguments: [
                "-C", directory, "rev-parse", "--verify", "-q", "stash@{0}",
            ])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            sha = nil
        }
        let trimmed = sha?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.isCommitSHA(trimmed) ? trimmed : nil
    }

    func trackedStashRestore(sha trackedStash: GitTrackedStash, in directory: String) async throws {
        guard case let .created(stashedSHA) = trackedStash else {
            // 未创建暂存:恢复必须是空操作——栈里的条目(若有)属于用户,
            // pop 会弹错对象。
            return
        }
        guard let sha = stashedSHA, Self.isCommitSHA(sha) else {
            try await stashPop(in: directory)
            return
        }
        let top = try await outputIgnoringGitFailure(arguments: [
            "-C", directory, "rev-parse", "--verify", "stash@{0}",
        ])
        let topSHA = top?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if topSHA == sha.lowercased() {
            try await stashPop(in: directory)
            return
        }
        // 栈被并发 stash 打乱:按 SHA 定位真实条目,apply 后**保留**该条——
        // 此时索引随时会漂移,drop 误删别人 stash 的代价远大于留一条冗余记录。
        let listOutput = try await outputIgnoringGitFailure(arguments: [
            "-C", directory, "stash", "list", "--format=%H",
        ])
        let shas = (listOutput ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let index = shas.firstIndex(of: sha.lowercased()) else {
            throw gitOperationError("Stash 栈已被其它操作改动，无法自动恢复本次自动暂存；请在“git stash list”中人工找回")
        }
        try await runGit(arguments: ["-C", directory, "stash", "apply", "stash@{\(index)}"])
    }

    func stashPush(in directory: String, message: String) async throws {
        try await runGit(arguments: [
            "-C", directory,
            "stash",
            "push",
            "--include-untracked",
            "--message", message,
        ])
    }

    func stashList(in directory: String) async -> [GitStashEntry] {
        let fieldSeparator = "\u{1F}"
        // 读取失败与"无 stash"都返回 []:列表页只读展示,空态已由 UI 区分,
        // 不为只读路径引入 throwing 接口。
        guard let output = await readGitOutput(operation: "stash-list", arguments: [
            "-C", directory,
            "stash", "list", "--format=%gs\(fieldSeparator)%cI",
        ]) else {
            return []
        }
        return GitStashEntry.parseList(output)
    }

    func popStash(at index: Int, in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "stash", "pop", "stash@{\(index)}"])
    }

    func dropStash(at index: Int, in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "stash", "drop", "stash@{\(index)}"])
    }

    func discardChanges(filePath: String, in directory: String) async throws {
        // 不做 trim:调用方传入的是 git 解析出的原始路径,首尾空格是合法文件名的一部分,
        // trim 后会把丢弃操作作用到另一个(改写过的)路径上。
        // pathspec 一律走 literalPathspec:文件名里的 `[ ] * ?` 在 git 默认的 wildmatch
        // 下会被当通配符命中另一个文件,`clean -f` 落在错文件上即不可恢复的数据破坏。
        let trimmedPath = filePath
        guard Self.isSafeRepositoryRelativePath(trimmedPath) else {
            throw gitOperationError("文件路径无效，无法丢弃改动")
        }

        switch try await runRawGit(arguments: ["-C", directory, "rev-parse", "--verify", "-q", "HEAD"]) {
        case .exited(0):
            // 先把该路径移出暂存区,再按 HEAD 是否含该文件二选一:
            // 有则恢复内容(覆盖暂存+未暂存改动),无则按未跟踪文件删除。
            // reset 对各种文件状态均安全,失败不阻塞后续判断。
            try? await runGit(arguments: ["-C", directory, "reset", "-q", "HEAD", "--", Self.literalPathspec(trimmedPath)])
            switch try await runRawGit(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "cat-file", "-e", "HEAD:\(trimmedPath)",
            ]) {
            case .exited(0):
                try await runGit(arguments: [
                    "-c", "core.quotepath=false",
                    "-C", directory, "checkout", "HEAD", "--", Self.literalPathspec(trimmedPath),
                ])
            case .exited:
                try await runGit(arguments: [
                    "-c", "core.quotepath=false",
                    "-C", directory, "clean", "-f", "--", Self.literalPathspec(trimmedPath),
                ])
            case .crashed(let message):
                throw gitOperationError(message)
            }
        case .exited:
            // 无提交的仓库(unborn HEAD):所有文件都视同未跟踪,直接删除。
            try await runGit(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "clean", "-f", "--", Self.literalPathspec(trimmedPath),
            ])
        case .crashed(let message):
            throw gitOperationError(message)
        }
    }

    func defaultBranch(for remoteURL: String) async -> String? {
        if let cached = RemoteDefaultBranchCache.shared.branch(for: remoteURL) {
            return cached
        }
        guard (try? GitURLParser.validateRemoteURL(remoteURL)) != nil else {
            return nil
        }
        // 与 remoteBranches 同款 20s:ls-remote 类探测弱网时快速失败,
        // 表单探测/默认分支回退都不该让用户对着 60s 的转圈干等。
        guard let output = await readGitOutput(operation: "default-branch-probe", arguments: [
            "ls-remote", "--symref", remoteURL, "HEAD"
        ], timeout: 20) else {
            return nil
        }
        let branch = Self.parseSymrefLsRemote(output: output).defaultBranch
        if let branch {
            RemoteDefaultBranchCache.shared.store(branch, for: remoteURL)
        }
        return branch
    }

    func defaultBranch(in directory: String) async -> String? {
        if let output = await readGitOutput(operation: "default-branch-local", arguments: [
            "-C", directory,
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ]) {
            let ref = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.hasPrefix("origin/") {
                return String(ref.dropFirst("origin/".count))
            }
        }

        guard let remoteURL = await remoteURL(in: directory) else {
            return nil
        }
        return await defaultBranch(for: remoteURL)
    }

    func currentBranch(in directory: String) async -> String? {
        guard let output = await readGitOutput(operation: "current-branch", arguments: ["-C", directory, "branch", "--show-current"]) else {
            return nil
        }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        guard let output = await readGitOutput(operation: "branch-status", arguments: [
            "-C", directory,
            "status",
            "--porcelain=2",
            "--branch",
        ]) else {
            return nil
        }
        return GitBranchStatusSnapshot.parsePorcelainV2(output)
    }

    func branches(in directory: String) async -> [String] {
        // 读取失败与"无本地分支"都返回 []:分支面板空态已可区分,与 stashList 同款取舍。
        guard let output = await readGitOutput(operation: "branches", arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads",
        ]) else {
            return []
        }

        let branches = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { branch in
                branch.isEmpty == false &&
                branch != "HEAD"
            }

        return Array(Set(branches)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func branchSnapshotInfo(in directory: String) async -> BranchSnapshotInfo? {
        async let statusTask = runGitOutput(arguments: [
            "-C", directory,
            "status",
            "--porcelain=2",
            "--branch",
        ])
        async let branchesTask = runGitOutput(arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads",
        ])

        let statusOutput: String
        do {
            statusOutput = try await statusTask
        } catch {
            logSnapshotReadFailure(error, command: "status --porcelain=2 --branch", directory: directory)
            return nil
        }
        var status = GitBranchStatusSnapshot.parsePorcelainV2(statusOutput)

        let branchesOutput: String?
        do {
            branchesOutput = try await branchesTask
        } catch {
            logSnapshotReadFailure(error, command: "for-each-ref refs/heads", directory: directory)
            branchesOutput = nil
        }

        let branchList: [String]
        if let branchesOutput {
            branchList = branchesOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false && $0 != "HEAD" }
        } else {
            branchList = []
        }

        let sortedBranches = Array(Set(branchList)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        // 只有存在冲突文件时才多跑一次 rev-parse 探测进行中的操作,
        // 避免每次 5 秒刷新都为干净仓库增加一个 git 子进程。
        if status.hasConflicts {
            status.interruptedOperation = await detectInterruptedOperation(in: directory)
        }

        return BranchSnapshotInfo(
            currentBranch: status.currentBranch,
            branches: sortedBranches,
            status: status
        )
    }

    /// 分支快照读取失败留痕。此前这一路是 `try?` 全量吞掉:fd 耗尽那类**进程级**失败
    /// (60s 超时/输出超限/进程启动失败)在用户侧只剩"仓库状态永远加载不出来、
    /// 点刷新也没反应",且没有任何可查痕迹。
    ///
    /// 只上报进程级失败:git 真实非零退出(仓库损坏、目录已不在)与任务取消都是常态,
    /// 详情页 30s 轮询 × N 个仓库会把它们刷成噪声。
    private func logSnapshotReadFailure(
        _ error: any Error,
        command: String,
        directory: String
    ) {
        guard error is GitServiceError == false, error is CancellationError == false else { return }
        gitServiceLog.error(
            "event=git_snapshot_read_failed command=\(command, privacy: .public) path=\(directory, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
        )
    }

    func createBranch(_ branch: String, fromRev rev: String, in directory: String) async throws {
        let trimmedRev = rev.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedRev.isEmpty == false else {
            throw gitOperationError("起始提交或分支不能为空")
        }
        // rev 进 revs 参数(`checkout -b <branch> <rev> --`),无 `--` 保护,过守卫;
        // 允许完整 commit SHA。
        guard Self.isSafeRefName(trimmedRev) || Self.isCommitSHA(trimmedRev) else {
            throw gitOperationError("起始点标识不合法")
        }
        // 新分支名同样是外来输入,必须过守卫。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        // 与 createLocalBranch 同款:末尾 `--` 防分支名被解析成路径/选项歧义。
        try await runGit(arguments: ["-C", directory, "checkout", "-b", branch, trimmedRev, "--"])
    }

    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws {
        let trimmedBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBase.isEmpty == false else {
            throw gitOperationError("远端基线分支不能为空")
        }
        // 新分支名是外来输入,必须过守卫(基线由 fetchRemoteBranchReference 校验)。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        // 先强制刷新基线的远端跟踪引用:远端列表是弹窗打开时的探测快照,
        // 期间分支可能已更新或被删除——fetch 失败即如实报错,不基于过期引用建分支。
        try await fetchRemoteBranchReference(trimmedBase, in: directory)
        // 末尾 `--` 与既有 createBranch 同款(实测不影响 rev 解析,
        // 且保留"同名文件歧义"的防护)。
        try await runGit(arguments: [
            "-C", directory, "checkout", "-b", branch, "origin/\(trimmedBase)", "--",
        ])
    }

    func commitDetail(hash: String, in directory: String) async -> GitCommitDetail? {
        // 只接受十六进制 commit ID(来自提交列表),避免把任意字符串当 rev 传给 git。
        // 判定口径与 isCommitSHA 一致用 ASCII 字符集(见其注释),不用 `\.isHexDigit`。
        guard Self.isHexObjectID(hash) else {
            return nil
        }
        guard let output = await readGitOutput(operation: "commit-detail", arguments: [
            "-C", directory,
            "show",
            "-s",
            "--format=%H\u{01}%an\u{01}%ae\u{01}%aI\u{01}%B",
            hash,
        ]) else {
            return nil
        }
        return GitCommitDetail.parseShow(output)
    }

    /// 探测仓库当前处于哪种可中止的操作;无 git 目录或无标记时返回 nil。
    func detectInterruptedOperation(in directory: String) async -> GitInterruptedOperation? {
        guard let gitDirectory = await absoluteGitDirectory(in: directory) else { return nil }
        return GitInterruptedOperation.detect(gitDirectoryPath: gitDirectory) { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// `git rev-parse --absolute-git-dir`,返回如 `/repo/.git`(worktree 下为各自 gitdir)。
    private func absoluteGitDirectory(in directory: String) async -> String? {
        guard let output = await readGitOutput(operation: "git-dir-resolve", arguments: [
            "-C", directory,
            "rev-parse",
            "--absolute-git-dir",
        ]) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func abortInterruptedOperation(in directory: String) async throws -> GitInterruptedOperation {
        guard let operation = await detectInterruptedOperation(in: directory) else {
            throw gitOperationError("当前没有可中止的 Git 操作")
        }
        try await runGit(arguments: ["-C", directory] + operation.abortArguments)
        return operation
    }

    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata] {
        guard let output = await readGitOutput(operation: "branch-metadata", arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)%01%(committerdate:unix)%01%(upstream:track)%01%(upstream)",
            "refs/heads",
        ]) else {
            return [:]
        }
        return GitBranchMetadata.parseForEachRef(output)
    }

    func remoteURL(in directory: String) async -> String? {
        guard let output = await readGitOutput(operation: "remote-url", arguments: ["-C", directory, "remote", "get-url", "origin"]) else {
            return nil
        }
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    func checkoutBranch(_ branch: String, in directory: String) async throws {
        // branch 会进 revs 参数(`switch -- <branch>` 后仍参与 rev 解析),外来名先过守卫。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        do {
            try await runGit(arguments: ["-C", directory, "switch", "--", branch])
            return
        } catch let checkoutError {
            guard isBranchNotFoundError(checkoutError) else {
                throw checkoutError
            }

            if try await checkoutRemoteTrackingBranchIfAvailable(branch, in: directory) {
                return
            }

            try await createLocalBranch(branch, in: directory)
        }
    }

    func createLocalBranch(_ branch: String, in directory: String) async throws {
        // branch 进 revs 参数(`checkout -b <branch> --`),外来名先过守卫。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        try await runGit(arguments: ["-C", directory, "checkout", "-b", branch, "--"])
    }

    func deleteLocalBranch(_ branch: String, in directory: String) async throws {
        // 与建分支/切分支同一守卫口径:branch 走 revs 参数、`--` 分离已防选项注入,
        // 但坏 ref 名会让 git 报英文底层错误,守卫后统一为中文提示。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        do {
            try await runGit(arguments: ["-C", directory, "branch", "-d", "--", branch])
        } catch {
            guard Self.isBranchNotFullyMergedError(error) else { throw error }
            try await runGit(arguments: ["-C", directory, "branch", "-D", "--", branch])
        }
    }

    func deleteRemoteBranch(_ branch: String, in directory: String) async throws {
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        try await runGit(arguments: ["-C", directory, "push", "origin", "--delete", "--", branch])
    }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }
        guard let defaultBranch = await defaultBranch(in: directory) else {
            throw gitOperationError("无法识别仓库默认分支")
        }
        // 默认分支可能来自远端 origin/HEAD 或 ls-remote 返回(远端可控),拼进
        // fetch/merge 参数前先过 ref 名守卫——含空格/选项样式的值会拼出非法甚至
        // 有歧义的命令行,统一按"识别失败"报错。
        guard Self.isSafeRefName(defaultBranch) else {
            throw gitOperationError("无法识别仓库默认分支")
        }
        guard currentBranch != defaultBranch else {
            return .skipped
        }

        try await runGit(arguments: ["-C", directory, "fetch", "origin", "--", defaultBranch])
        // fetch 成功:远端引用已刷新,失效默认分支缓存(粗粒度整体清空,取舍见缓存注释)。
        RemoteDefaultBranchCache.shared.invalidateAll()
        try await runGit(arguments: ["-C", directory, "merge", "--no-edit", "--", "origin/\(defaultBranch)"])
        return .merged
    }

    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] {
        await recentCommits(in: directory, count: count, rev: nil)
    }

    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        if let rev, !Self.isSafeRefName(rev) { return [] }
        // 读取失败与"无提交"都返回 []:提交列表空态已由 UI 区分,与 unpushedCommits 同款取舍。
        return await commitLogEntries(in: directory, count: count, skip: 0, range: rev, options: [])
    }

    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry] {
        await unpushedCommits(in: directory, count: count, rev: nil)
    }

    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        if let rev, !Self.isSafeRefName(rev) { return [] }
        // 无上游分支时 `@{u}` 解析失败,返回空;调用方以 hasRemoteTrackingBranch 区分展示。
        let range = Self.commitLogRange(rev: rev, unpushedOnly: true)
        return await commitLogEntries(in: directory, count: count, skip: 0, range: range, options: [])
    }

    func commitLogPage(_ request: CommitLogPageRequest) async -> GitCommitLogPage {
        if let rev = request.rev, !Self.isSafeRefName(rev) { return .empty }
        let count = max(1, request.count)
        let skip = max(0, request.skip)
        let range = Self.commitLogRange(rev: request.rev, unpushedOnly: request.unpushedOnly)

        guard let searchText = Self.normalizedCommitLogSearchText(request.searchText) else {
            // 非搜索态:`--skip` 在 git 侧过滤之后生效,是精确的结果级游标,
            // 每页只取 pageSize+1 条,翻页不必从仓库头重拉。
            let entries = await commitLogEntries(in: request.directory, count: count + 1, skip: skip, range: range, options: [])
            return GitCommitLogPage(commits: Array(entries.prefix(count)), hasMore: entries.count > count)
        }

        // 搜索态:`--grep` 与 `--author` 混用是**与**语义(git 2.54 实测,并非直觉上的"或"),
        // "说明或作者任一命中"只能两路查询再在内存取并集。两路都用作者时间倒序,
        // 并集第 skip+count 名之前的命中必然落在各自前缀里,故各取 headCount 条即可。
        let headCount = skip + count + 1
        async let messageMatches = commitLogEntries(
            in: request.directory,
            count: headCount,
            skip: 0,
            range: range,
            options: Self.commitLogSearchOptions(pattern: "--grep=\(searchText)")
        )
        async let authorMatches = commitLogEntries(
            in: request.directory,
            count: headCount,
            skip: 0,
            range: range,
            options: Self.commitLogSearchOptions(pattern: "--author=\(searchText)")
        )
        // 关键词形如 object ID 时补一路直达查询:`--grep` 匹配不到哈希。
        // "仅看未推送"下不做这路:未推送集合由 range 严格界定,把仓库里任意
        // 可解析的同名对象塞进结果集会破坏该筛选的语义。
        var lists: [[GitCommitEntry]] = [await messageMatches, await authorMatches]
        if request.unpushedOnly == false, Self.isHexObjectID(searchText, maxLength: 64) {
            lists.append(await commitLogEntries(in: request.directory, count: 1, skip: 0, range: searchText, options: []))
        }
        return Self.mergeCommitLogMatches(lists, skip: skip, count: count)
    }

    /// 提交日志的 revs 范围:"仅看未推送"取 `<rev>@{u}..<rev>`(未指定 rev 时 `@{u}..HEAD`),
    /// 否则取指定 ref;两者皆无时为 nil(从 HEAD 走全部历史)。
    private static func commitLogRange(rev: String?, unpushedOnly: Bool) -> String? {
        guard unpushedOnly else { return rev }
        return rev.map { "\($0)@{u}..\($0)" } ?? "@{u}..HEAD"
    }

    /// 搜索关键词归一:换行折成空格(`--grep` 的模式串按行匹配,带换行只会永远落空),
    /// 去首尾空白;归一后为空返回 nil 表示不过滤。
    /// 标记为 internal:纯函数,单测直接覆盖。
    static func normalizedCommitLogSearchText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// 搜索态附加给 `git log` 的选项。`-F` 让关键词按字面量子串匹配(UI 的搜索语义如此,
    /// 也免得用户输入的 `(`/`[` 被当正则;git 2.54 实测它同时作用于 `--grep` 与 `--author`),
    /// `-i` 忽略大小写,`--author-date-order` 把两路结果钉到与列表展示同一个时间键,
    /// 并集分页窗口才稳定。
    private static func commitLogSearchOptions(pattern: String) -> [String] {
        ["-F", "-i", "--author-date-order", pattern]
    }

    /// 合并多路命中:按哈希去重、按作者时间倒序(同刻按哈希),再取并集窗口 [skip, skip+count)。
    private static func mergeCommitLogMatches(_ lists: [[GitCommitEntry]], skip: Int, count: Int) -> GitCommitLogPage {
        var seen: Set<String> = []
        var merged: [GitCommitEntry] = []
        for list in lists {
            for entry in list where seen.insert(entry.hash).inserted {
                merged.append(entry)
            }
        }
        merged.sort { lhs, rhs in
            lhs.date == rhs.date ? lhs.hash < rhs.hash : lhs.date > rhs.date
        }
        let window = Array(merged.dropFirst(skip).prefix(count))
        return GitCommitLogPage(commits: window, hasMore: merged.count > skip + count)
    }

    /// 取一页 `git log` 并解析;读取失败与"无提交"都返回 []。
    private func commitLogEntries(
        in directory: String,
        count: Int,
        skip: Int,
        range: String?,
        options: [String]
    ) async -> [GitCommitEntry] {
        guard let output = await commitLogOutput(in: directory, count: count, skip: skip, range: range, options: options) else {
            return []
        }
        return Self.parseCommitLog(output)
    }

    /// 执行 `git log` 并返回原始输出;`range` 为可选的提交范围(如 "@{u}..HEAD")，
    /// `skip` 是结果级偏移，`options` 是搜索态附加的过滤选项。
    private func commitLogOutput(
        in directory: String,
        count: Int,
        skip: Int = 0,
        range: String?,
        options: [String] = []
    ) async -> String? {
        // 钳制到至少 1:count <= 0 会拼出 `git log -0`,git 直接报错。
        let clampedCount = max(1, count)
        let fieldSeparator = "\u{1F}"
        let format = "%H\(fieldSeparator)%s\(fieldSeparator)%an\(fieldSeparator)%aI"
        var arguments = [
            "-C", directory,
            "log",
            "--format=\(format)",
        ]
        arguments.append(contentsOf: options)
        if skip > 0 {
            arguments.append("--skip=\(skip)")
        }
        arguments.append("--numstat")
        arguments.append("-\(clampedCount)")
        if let range {
            // 注意:rev range 必须直接作为 revs 参数,不能放在 `--` 之后(`--` 后是路径语义)。
            arguments.append(range)
        }
        return await readGitOutput(operation: "commit-log", arguments: arguments)
    }

    /// 解析 `git log --format=… --numstat` 输出。
    /// 元数据行内部用 \x1F 分隔字段,避免与提交信息冲突。
    /// git log 会把 format 段与 numstat 段交替输出:
    ///   元数据行\n [\n]numstat行...\n 元数据行\n [\n]numstat行...\n ...
    /// 因此用基于行的状态机解析:含 \x1F 的是元数据行(新记录),
    /// 其余非空行是上一条记录的 numstat。
    private static func parseCommitLog(_ output: String) -> [GitCommitEntry] {
        let fieldSeparator = "\u{1F}"
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        // 先逐行收集:元数据行 + 其后跟随的 numstat 行。
        var entries: [GitCommitEntry] = []
        var pendingMeta: (hash: String, subject: String, author: String, date: Date)?
        var pendingInsertions = 0
        var pendingDeletions = 0
        var pendingFiles = 0

        func flushPending() {
            guard let meta = pendingMeta else { return }
            entries.append(GitCommitEntry(
                hash: meta.hash,
                subject: meta.subject,
                author: meta.author,
                date: meta.date,
                filesChanged: pendingFiles,
                insertions: pendingInsertions,
                deletions: pendingDeletions
            ))
            pendingMeta = nil
            pendingInsertions = 0
            pendingDeletions = 0
            pendingFiles = 0
        }

        for line in output.components(separatedBy: .newlines) {
            if line.contains(fieldSeparator) {
                // 新的元数据行:先把上一条落盘。
                flushPending()
                let parts = line.components(separatedBy: fieldSeparator)
                // `>= 4` + 中段回拼:提交标题可以合法含 \u{1F} 字符(任意 UTF-8 文本),
                // 精确 4 段判定会把这样的记录整条丢弃——与 GitStashEntry.parseList
                // 对消息字段的同款纠偏一致。
                guard parts.count >= 4 else { continue }
                pendingMeta = (
                    hash: parts[0],
                    subject: parts[1..<(parts.count - 2)].joined(separator: fieldSeparator),
                    author: parts[parts.count - 2],
                    date: dateFormatter.date(from: parts[parts.count - 1]) ?? .distantPast
                )
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      pendingMeta != nil {
                // numstat 行:"12\t3\tpath/to/file"(二进制文件首列为 "-")
                pendingFiles += 1
                let cols = line.components(separatedBy: "\t")
                if cols.count >= 2 {
                    if let add = Int(cols[0]) { pendingInsertions += add }
                    if let del = Int(cols[1]) { pendingDeletions += del }
                }
            }
        }
        flushPending()

        return entries
    }

    func diffWorkingDirectory(in directory: String) async throws -> [GitDiffEntry] {
        var entries: [GitDiffEntry]
        do {
            // `git diff HEAD` 反映已暂存和已跟踪文件的改动;
            // 但未 `git add` 的 untracked 文件不在其中(git 的固有行为)。
            let output = try await runGitOutput(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "HEAD", "--numstat", "-p", "--no-color",
            ])
            entries = GitDiffParser.parse(output: output)
        } catch {
            // 无 commit 的仓库:`git diff HEAD` 会失败,回退到仅未暂存的 diff。
            // 只在"HEAD 这类修订名解析不了"时回退:超时/取消/非仓库等失败,回退那条
            // 命令同样会失败,却要多等一个完整超时(最长从 60s 翻倍到 120s)。
            guard Self.isUnresolvableRevisionError(error) else { throw error }
            // 回退仍失败则如实上抛(取消/非仓库等),不吞成空 diff。
            let rawOutput = try await runGitOutput(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "--numstat", "-p", "--no-color",
            ])
            entries = GitDiffParser.parse(output: rawOutput)
        }

        // 补充 untracked 文件:`git diff --no-index /dev/null <file>` 为每个新文件生成 diff。
        // 该命令有差异时退出码为 1,属正常行为。限制最多处理 100 个文件,避免过多时卡顿。
        // 补充 untracked 文件:`git diff --no-index /dev/null <file>` 为每个新文件生成 diff。
        // 该命令有差异时退出码为 1,属正常行为。限制最多处理这么多文件,避免过多时卡顿。
        let untracked = await untrackedFiles(in: directory)
        let trackedPaths = Set(entries.map(\.filePath))
        var pending: [(index: Int, file: String)] = []
        for (offset, file) in untracked.prefix(Self.untrackedDisplayLimit).enumerated() where trackedPaths.contains(file) == false {
            pending.append((index: offset, file: file))
        }
        guard pending.isEmpty == false else { return entries }

        // 有界并发跑 git:每个 untracked 文件一次进程,串行会在多文件时叠加启动开销,
        // 一次性全量入队又会同时拉起上百个 git 进程,4 是与分支拉取一致的平衡点。
        // 结果按 index 回填,最终仍按 ls-files 的顺序 append;单文件失败(权限、文件
        // 被并发移走)只跳过该文件,取消原样上抛,不吞成"少了一个文件"的假静默。
        var patchesByIndex: [Int: String] = [:]
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            let maxConcurrentDiffTasks = 4
            var nextIndex = 0

            func addTask() {
                guard nextIndex < pending.count else { return }
                let item = pending[nextIndex]
                nextIndex += 1
                group.addTask { () -> (Int, String?) in
                    do {
                        let patch = try await runGitOutput(
                            arguments: [
                                "-c", "core.quotepath=false",
                                "-C", directory, "diff", "--no-index", "--numstat", "-p", "--no-color",
                                "--", "/dev/null", item.file,
                            ],
                            allowedExitCodes: [0, 1]
                        )
                        return (item.index, patch)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (item.index, nil)
                    }
                }
            }

            for _ in 0..<min(maxConcurrentDiffTasks, pending.count) {
                addTask()
            }
            while let (index, patch) = try await group.next() {
                if let patch {
                    patchesByIndex[index] = patch
                }
                addTask()
            }
        }

        for item in pending {
            guard let patch = patchesByIndex[item.index] else { continue }
            entries.append(contentsOf: GitDiffParser.parse(output: patch))
        }

        return entries
    }

    /// 列出工作区中未跟踪的文件(排除 .gitignore 命中的文件)。
    private func untrackedFiles(in directory: String) async -> [String] {
        guard let output = await readGitOutput(operation: "untracked-files", arguments: [
            "-c", "core.quotepath=false",
            "-C", directory, "ls-files", "--others", "--exclude-standard", "-z",
        ]) else {
            return []
        }
        // `-z` 以 NUL 分隔:文件名里可以有换行、引号、首尾空格,NUL 分隔不会像
        // 按 \n 切分那样被截断或改写,下游 --no-index diff 才能拿到真实路径。
        return output
            .components(separatedBy: "\0")
            .filter { $0.isEmpty == false }
    }

    func diffCommit(hash: String, in directory: String) async throws -> [GitDiffEntry] {
        // hash 进 revs 参数位置、后面没有 `--` 可依赖:必须以 `-` 开头的串会被 git 当选项
        // (如 `--output=<file>` 写文件;配了 diff.external 时更可触发外部命令),
        // 口径与 commitDetail/blobContent 一致——先过守卫,再加 --end-of-options 兜底。
        // 守卫拒绝必须抛错而非吞成 []:空数组在这里与"该提交无改动"的合法结果
        // 不可区分,静默返回会让窗口展示一个语义完全错误的"空 diff"。
        guard Self.isHexObjectID(hash, maxLength: 64) || Self.isCommitSHA(hash) else {
            throw gitOperationError("提交标识非法，无法读取其改动")
        }
        // `--first-parent`:merge commit 的 `git show -p` 默认走 combined diff,
        // 干净合并时 patch 为空,而 `--numstat` 仍按第一父提交统计,
        // 会出现"文件列表有、diff 内容为空";统一按第一父提交取 diff 保证两者一致。
        // hash 非法/引用缺失/取消等失败如实抛错,不再被 `try?` 吞成"两侧内容完全一致"。
        let output = try await runGitOutput(
            arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "show", "--first-parent", "--numstat", "-p", "--no-color",
                "--format=", "--end-of-options", hash,
            ],
            allowedExitCodes: [0, 1]
        )
        return GitDiffParser.parse(output: output)
    }

    /// 指定修订版本中某文件的完整内容(`git cat-file blob <revision>:<path>`)。
    ///
    /// 「展示所有行」取历史 diff 新侧全文用:路径在该版本不存在(被删除的文件)
    /// 或指向子模块(commit 对象,非 blob)时命令失败,`try?` 回退为 nil,按不展开处理。
    func blobContent(revision: String, path: String, in directory: String) async -> String? {
        // revision 进 revs 参数、path 进 object 名,两者都必须过守卫:
        // 否则任意 revision 字符串可读仓库内任意 blob(如 .git 配置对象)。
        guard Self.isSafeRefName(revision) || Self.isCommitSHA(revision) else { return nil }
        guard Self.isSafeRepositoryRelativePath(path) else { return nil }
        return await readGitOutput(operation: "blob-content", arguments: [
            "-C", directory, "cat-file", "blob", "\(revision):\(path)",
        ])
    }

    /// 提交工作区全部改动。
    ///
    /// 先 `git add --all` 把已暂存、未暂存与 untracked 文件全部纳入(与 diffWorkingDirectory
    /// 展示的范围一致),再统一 commit;若 commit 失败(如未配置 user.name/user.email),
    /// 改动会留在暂存区,补齐配置后重试即可,add 幂等。
    func commitAllChanges(message: String, in directory: String) async throws {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedMessage.isEmpty == false else {
            throw gitOperationError("提交信息不能为空")
        }
        try await runGit(arguments: ["-C", directory, "add", "--all"])
        try await runGit(arguments: ["-C", directory, "commit", "-m", trimmedMessage])
    }

    /// 两个分支之间的 diff(`git diff <base>..<head>`)。
    ///
    /// `head` 为当前分支时改为 `git diff <base>`(base → 工作区):包含未提交改动,
    /// 与仓库行的"未提交"提示一致——"与远端 main 对比"要看的正是本地相对远端的
    /// 全部差异;两个非当前分支之间仍按提交对比。
    func diffBranches(base: String, head: String, in directory: String) async throws -> [GitDiffEntry] {
        // revs 参数无 `--` 保护,外来 ref 先过守卫(见 isSafeRefName 注释)。
        // 守卫拒绝抛错而非吞 []:空数组与"两分支无差异"不可区分,静默返回
        // 会展示语义错误的空 diff(同 diffCommit 口径)。
        guard Self.isSafeRefName(base), Self.isSafeRefName(head) else {
            throw gitOperationError("分支名称非法，无法比较改动")
        }
        let currentBranch = await currentBranch(in: directory)
        let range = (head == currentBranch) ? base : "\(base)..\(head)"
        // `git diff` 在存在差异时退出码为 1,属正常,需允许。
        // `-c core.quotepath=false` 让中文等非 ASCII 路径以 UTF-8 原样输出,而非八进制转义。
        // 超时/取消/引用失败如实抛错,不再被 `try?` 吞成"两侧内容完全一致"。
        let output = try await runGitOutput(
            arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "--numstat", "-p", "--no-color", range,
            ],
            allowedExitCodes: [0, 1]
        )
        return GitDiffParser.parse(output: output)
    }

    func divergence(base: String, head: String, in directory: String) async -> GitRefDivergence? {
        guard Self.isSafeRefName(base), Self.isSafeRefName(head) else { return nil }
        guard let output = await readGitOutput(operation: "divergence", arguments: [
            "-C", directory,
            "rev-list",
            "--left-right",
            "--count",
            "\(base)...\(head)",
        ]) else {
            return nil
        }
        return GitRefDivergence.parse(output)
    }

    func remoteBranches(for remoteURL: String) async -> [String]? {
        guard (try? GitURLParser.validateRemoteURL(remoteURL)) != nil else { return nil }
        // 分支弹窗远端页签的实时名单:网络不通/慢时按默认 60s 干等,
        // 用户体感就是"卡死";ref 列表探测 20s 未响应即按失败处理,
        // 弹窗内提供重试/刷新入口,不再阻塞等待。
        // 失败返回 nil(而非 []):`ls-remote` 非零退出(auth/网络/坏 URL)与
        // "远端确实没有分支"必须可区分,否则调用方一次抖动就会把可用的旧名单
        // 覆盖成空列表(stale 缓存污染)。
        guard let output = await readGitOutput(operation: "remote-branches", arguments: [
            "ls-remote", "--heads", remoteURL
        ], timeout: 20) else { return nil }

        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                // Format: "abc1234\trefs/heads/branch-name"
                let parts = trimmed.components(separatedBy: "\t")
                guard parts.count == 2 else { return nil }
                let ref = parts[1]
                let prefix = "refs/heads/"
                guard ref.hasPrefix(prefix) else { return nil }
                return String(ref.dropFirst(prefix.count))
            }
    }

    /// 表单远端探测:一次 `ls-remote --symref`(带 `HEAD refs/heads/*` pattern
    /// 限定输出规模)同时得到分支列表与默认分支,替代分头两次联网查询。
    func probeRemoteInfo(for remoteURL: String) async -> (branches: [String], defaultBranch: String?) {
        guard (try? GitURLParser.validateRemoteURL(remoteURL)) != nil else { return ([], nil) }
        // 表单远端探测是最该快失败的路径:与 remoteBranches 统一 20s(此前 60s,弱网干等)。
        guard let output = await readGitOutput(operation: "probe-remote-info", arguments: [
            "ls-remote", "--symref", remoteURL, "HEAD", "refs/heads/*",
        ], timeout: 20) else { return ([], nil) }
        let parsed = Self.parseSymrefLsRemote(output: output)
        if let defaultBranch = parsed.defaultBranch {
            RemoteDefaultBranchCache.shared.store(defaultBranch, for: remoteURL)
        }
        return parsed
    }

    /// 解析 `git ls-remote --symref` 全量输出为 (分支列表, 默认分支)。
    /// 行形态有两类:
    /// - `ref: refs/heads/main\tHEAD`——HEAD 的符号指向,即默认分支;
    /// - `<sha>\t<refname>`——常规引用;`<sha>\tHEAD` 与 refs/heads/ 之外的引用跳过。
    /// 标记为 internal:纯函数,供单测直接覆盖各分支。
    static func parseSymrefLsRemote(output: String) -> (branches: [String], defaultBranch: String?) {
        var branches: [String] = []
        var defaultBranch: String?
        let headsPrefix = "refs/heads/"
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if trimmed.hasPrefix("ref:") {
                // 符号引用行整形如 `ref: refs/heads/main\tHEAD`:先按 tab 切断尾部,再取指向。
                let firstField = trimmed.split(separator: "\t", maxSplits: 1).first ?? ""
                let target = firstField.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
                guard target.hasPrefix(headsPrefix) else { continue }
                let name = String(target.dropFirst(headsPrefix.count))
                if name.isEmpty == false { defaultBranch = name }
                continue
            }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count == 2, parts[1].hasPrefix(headsPrefix) else { continue }
            let name = String(parts[1].dropFirst(headsPrefix.count))
            if name.isEmpty == false { branches.append(name) }
        }
        return (branches, defaultBranch)
    }

    /// 列出本地已有的远端跟踪分支(`git for-each-ref refs/remotes`,如 origin/main);
    /// 只读本地引用,不联网。排除 origin/HEAD 这类符号引用。
    /// 读取失败与"无远端"都返回 []:与 branches/stashList 同款取舍,不为只读路径引入 throwing 接口。
    func remoteTrackingBranches(in directory: String) async -> [String] {
        guard let output = await readGitOutput(operation: "remote-tracking-branches", arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/remotes",
        ]) else {
            return []
        }
        // 符号引用 refs/remotes/origin/HEAD 的 refname:short 是 "origin"(不带 /HEAD),
        // 统一按"必须含 /"过滤掉远端名裸条目。
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("/") }
    }

    func isGitAvailable() async -> Bool {
        await gitEnvironmentInfo().isAvailable
    }

    func gitEnvironmentInfo() async -> GitEnvironmentInfo {
        let version = (await readGitOutput(operation: "git-version", arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitEnvironmentInfo(
            isAvailable: version?.isEmpty == false,
            version: version?.isEmpty == false ? version : nil,
            executablePath: GitProcessRunner.gitExecutablePath
        )
    }

    private func trackingBranch(in directory: String) async -> String? {
        guard let output = await readGitOutput(operation: "upstream-tracking-branch", arguments: [
            "-C", directory,
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ]) else {
            return nil
        }

        let trackingBranch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trackingBranch.isEmpty ? nil : trackingBranch
    }

    private func checkoutRemoteTrackingBranchIfAvailable(
        _ branch: String,
        in directory: String
    ) async throws -> Bool {
        do {
            try await runGit(arguments: [
                "-C", directory,
                "checkout",
                "--track",
                "origin/\(branch)",
            ])
            return true
        } catch {
            guard await remoteURL(in: directory) != nil else {
                return false
            }

            do {
                try await fetchRemoteBranchReference(branch, in: directory)
                try await runGit(arguments: [
                    "-C", directory,
                    "checkout",
                    "--track",
                    "origin/\(branch)",
                ])
                return true
            } catch {
                if isMissingRemoteBranchError(error) {
                    return false
                }
                throw error
            }
        }
    }

    private func fetchRemoteBranchReference(
        _ branch: String,
        in directory: String
    ) async throws {
        // branch 拼进 refspec(`+refs/heads/<branch>:...`),无 `--` 可加,外来名先过守卫。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        try await runGit(arguments: [
            "-C", directory,
            "fetch",
            "origin",
            // refspec 带 `+` 强制更新远端跟踪引用:不带时远端新值不是本地跟踪引用
            // 的祖先(如 force-push 过)会被 git 以 non-fast-forward 拒绝,
            // 而这正是"fetch 刷新过期引用"最该覆盖的场景。更新跟踪引用无风险。
            "+refs/heads/\(branch):refs/remotes/origin/\(branch)",
        ])
    }

    private func isMissingRemoteBranchError(_ error: Error) -> Bool {
        guard let gitError = error as? GitServiceError else { return false }
        let message = gitError.stderr.lowercased()
        return message.contains("couldn't find remote ref") ||
            message.contains("could not find remote ref") ||
            message.contains("remote ref does not exist") ||
            message.contains("is not a commit and a branch") ||
            message.contains("invalid reference")
    }

    /// 本地分支切不过去、应尝试"跟踪远端同名分支/自动建分支"兜底的报错特征。
    /// 只匹配 git switch/checkout 对无效 rev 的精确文案:此前 `contains("pathspec")`
    /// / `did not match any` 过宽,会把其它类别的失败(如损坏的仓库状态)误判成
    /// "分支不存在"而兜底新建同名分支,掩盖真实故障。
    private func isBranchNotFoundError(_ error: Error) -> Bool {
        guard let gitError = error as? GitServiceError else { return false }
        let message = gitError.stderr.lowercased()
        return message.contains("invalid reference") ||
            message.contains("not a valid branch name") ||
            message.contains("is not a commit and a branch")
    }

    /// `git fetch .` 更新被其它 worktree 检出的分支时 git 的拒绝特征。
    private static func isWorktreeCheckedOutError(_ error: GitServiceError) -> Bool {
        let message = error.stderr.lowercased()
        return message.contains("used by worktree") || message.contains("already checked out")
    }

    /// `git branch -d` 拒绝删除含未合并提交分支的报错特征,据此回退 `-D`。
    private static func isBranchNotFullyMergedError(_ error: Error) -> Bool {
        guard let gitError = error as? GitServiceError else { return false }
        return gitError.stderr.lowercased().contains("not fully merged")
    }

    /// 只在 git **命令真实失败**(非零退出)时降级为 nil 的读取(用于"查不到就走兜底"
    /// 的探测,如 stash 栈顶 SHA)。
    ///
    /// 其余错误必须原样上抛:`GitProcessExecutionError`(60s 超时/输出超限)、进程启动
    /// 失败的 `NSError` 都不是"栈里没有这条",折算成 nil 会退化成误判,进而抛出与事实
    /// 无关的"Stash 栈已被其它操作改动,请人工找回";取消同理,被吞掉的取消会失去
    /// 原样传播。
    private func outputIgnoringGitFailure(arguments: [String]) async throws -> String? {
        do {
            return try await runGitOutput(arguments: arguments)
        } catch is GitServiceError {
            // runGitOutput 的进程级错误(超时/输出超限/启动失败/取消)都不是
            // GitServiceError,走到这里只可能是 git 真实退出码非 0。
            return nil
        }
    }

    /// 只读查询的容错入口:与 `try?` 吞错等价,但失败必须留痕(命令名 + 原因)。
    /// 此前 20 余处读路径静默吞错,"角标没了/列表空了"在现场完全无从归因。
    private func readGitOutput(
        operation: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async -> String? {
        do {
            return try await runGitOutput(arguments: arguments, timeout: timeout)
        } catch {
            // 任务取消属正常生命周期事件,不是异常,不留痕。
            if error is CancellationError { return nil }
            gitServiceLog.error(
                "event=read_git_output_failed operation=\(operation, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func runGitOutput(arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        try await runGitOutput(arguments: arguments, allowedExitCodes: [0], timeout: timeout)
    }

    /// 与 `runGitOutput` 类似,但允许指定的退出码(用于 `git diff --no-index` 这类有差异时退出码非 0 的命令)。
    private func runGitOutput(arguments: [String], allowedExitCodes: Set<Int32>, timeout: TimeInterval = 60) async throws -> String {
        let result = try await runProcess(arguments: arguments, captureStdout: true, captureStderr: true, timeout: timeout)
        guard allowedExitCodes.contains(result.terminationStatus) else {
            let stderrMessage = GitServiceError.sanitizedStderr(
                Self.decodedOutput(result.stderrData)
            )
            throw GitServiceError.commandFailed(
                exitCode: result.terminationStatus,
                stderr: stderrMessage
            )
        }
        return Self.decodedOutput(result.stdoutData)
    }

    /// git 输出可能含非法 UTF-8(典型是 `core.quotepath=false` 时的非 UTF-8 文件名)。
    /// 直接 `?? ""` 会让整段报错退化成空串,真实原因彻底丢失——降级为有损解码,
    /// 非法字节替换为 U+FFFD,至少保住可读的部分。
    ///
    /// 标记为 internal 而非 private:这是无副作用的纯函数,暴露给测试可直接覆盖解码分支。
    static func decodedOutput(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// ref/rev 名字守卫:这些字符串会被拼进 `base..head`、`<rev>@{u}..<rev>`、
    /// `revision:path` 这类**无法加 `--` 分隔**的 revs 参数,必须自行挡住:
    /// 以 `-` 开头会被解析成选项;空白/换行/NUL 制造歧义参数或注入 argv;
    /// `..`/`@{` 允许外来值改写 range 语义;`:` 会改写 `revision:path` 的
    /// object 分隔语义(合法 git 引用名本就不含冒号)。
    /// 标记为 internal:纯函数,单测直接覆盖。
    static func isSafeRefName(_ ref: String) -> Bool {
        guard ref.isEmpty == false, ref.hasPrefix("-") == false else { return false }
        if ref.contains("..") || ref.contains("@{") || ref.contains(":") { return false }
        for scalar in ref.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return false } // 控制字符/NUL
            if Character(scalar).isWhitespace || Character(scalar).isNewline { return false }
        }
        return true
    }

    /// 只允许仓库内的相对路径:拒绝绝对路径和向上穿越的 `..`。
    /// 按路径**组件**判断而不是子串匹配,否则 `file..txt` 这类合法文件名会被误拒。
    /// 标记为 internal 以便直接单测各分支。
    static func isSafeRepositoryRelativePath(_ path: String) -> Bool {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.allSatisfy { $0 != ".." }
    }

    private func runGit(arguments: [String], timeout: TimeInterval = 60) async throws {
        let result = try await runProcess(arguments: arguments, captureStdout: false, captureStderr: true, timeout: timeout)
        guard result.terminationStatus == 0 else {
            let stderrMessage = GitServiceError.sanitizedStderr(
                Self.decodedOutput(result.stderrData)
            )
            throw GitServiceError.commandFailed(
                exitCode: result.terminationStatus,
                stderr: stderrMessage
            )
        }
    }

    private func runProcess(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60
    ) async throws -> GitProcessResult {
        try await GitProcessRunner().run(
            arguments: arguments,
            captureStdout: captureStdout,
            captureStderr: captureStderr,
            timeout: timeout,
            additionalEnvironment: additionalEnvironment
        )
    }

    private func gitOperationError(_ message: String) -> GitServiceError {
        .operationFailed(message: message)
    }
}
