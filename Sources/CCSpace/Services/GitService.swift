import Foundation
import os

private let gitServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "GitService"
)

enum GitServiceError: LocalizedError, Sendable {
    case commandFailed(stderr: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let stderr):
            if stderr.isEmpty { return "git 执行失败" }
            return Self.localizeMessage(stderr) ?? Self.redactCredentials(in: stderr)
        case .operationFailed(let message):
            return message
        }
    }

    var stderr: String {
        switch self {
        case .commandFailed(let stderr): return stderr
        case .operationFailed(let message): return message
        }
    }

    /// 未命中已知模式返回 nil(调用方保留原文并做凭据脱敏)。
    /// internal:UserFacingError 据此判断文案是否真的已转中文,不靠"含汉字"猜。
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
        // 收紧匹配:两词须同行才算"仓库不存在",防无关 stderr 同时含二词被误译;"remote:" 前缀单独放宽。
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

    /// git stderr 普遍回显完整远端 URL,用户常把 token 写进 `scheme://user:pass@host`;pass 段容 `/` 与空格、
    /// 用户名段不容(免误伤无凭据 URL)。宁可多打码也不漏——漏打等于把令牌显示在 UI/日志。
    private static let credentialPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "[A-Za-z][A-Za-z0-9+.\\-]*://[^/\\s:@]+(?::[^@\\s]+(?: +[^@\\s]+)*)?@",
            options: []
        )
    }()

    /// 匹配查询参数令牌(`?private_token=` 等):托管平台普遍支持参数传令牌,git fatal 消息会回显整个 URL;
    /// 打码口径必须与 `GitProcessRunner.redactedArgument` 同步演进,任一处漏打都会把令牌泄进 UI/日志。
    private static let tokenQueryPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "([?&][A-Za-z0-9_\\-]*token[A-Za-z0-9_\\-]*=)([^&\\s'\"]+)",
            options: [.caseInsensitive]
        )
    }()

    /// 文本级脱敏:未命中本地化规则的 stderr 会原样展示给用户,不脱敏等于泄露令牌。
    /// 与 `GitProcessRunner.redactedArgument`(作用于单个 argv)是两份独立实现,口径必须同步,测试对两边都有断言。
    static func redactCredentials(in text: String) -> String {
        redactTokenQueryValues(in: redactUserInfoCredentials(in: text))
    }

    private static func redactUserInfoCredentials(in text: String) -> String {
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

    private static func redactTokenQueryValues(in text: String) -> String {
        guard let regex = tokenQueryPattern else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1redacted"
        )
    }

    /// 剔除 OpenSSH 以 "** " 开头的建议性警告行(如后量子密钥交换提示):与命令成败无关,不应进入错误提示。
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

/// `trackedStashCreate` 的结果令牌:必须能区分"创建"与"未创建"——`git stash push` 无改动时
/// 打印 "No local changes to save" 仍退出 0(竞态),只回传栈顶 SHA 会让恢复侧 pop 用户既有 stash。
enum GitTrackedStash: Equatable, Sendable {
    /// 已创建;栈顶 SHA,nil = 标识查询失败(调用方回退"弹栈顶")。
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
    /// 暂存当前改动(含 untracked),返回恢复侧可对账的 `GitTrackedStash` 令牌。
    func trackedStashCreate(in directory: String) async throws -> GitTrackedStash
    /// 恢复创建的暂存:先校验栈顶 SHA;被并发打乱则按 SHA 定位条目 apply(**不 drop**,错位索引不可信)。
    /// `.created(sha: nil)` 回退 `stashPop`;`.notCreated` 必须是空操作。
    func trackedStashRestore(sha: GitTrackedStash, in directory: String) async throws
    func defaultBranch(for remoteURL: String) async -> String?
    func defaultBranch(in directory: String) async -> String?
    func currentBranch(in directory: String) async -> String?
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot?
    /// 本地分支名单;`nil` = 读取失败,`[]` = 确无本地分支(口径同 `remoteBranches`)。
    /// 展示方据此 stale-while-revalidate 保留上次成功名单,不得把失败渲染成空仓库。
    func branches(in directory: String) async -> [String]?
    /// 本地已有的远端跟踪分支(如 origin/xxx,不含 */HEAD);仅读本地引用,不联网。
    /// `nil` = 读取失败,`[]` = 确无远端跟踪分支。
    func remoteTrackingBranches(in directory: String) async -> [String]?
    func branchSnapshotInfo(in directory: String) async -> BranchSnapshotInfo?
    func remoteURL(in directory: String) async -> String?
    func checkoutBranch(_ branch: String, in directory: String) async throws
    func createLocalBranch(_ branch: String, in directory: String) async throws
    /// 先 `git branch -d` 安全删除,含未合并提交时自动回退 `-D`;删除前的二次确认由调用方负责。
    func deleteLocalBranch(_ branch: String, in directory: String) async throws
    /// 删除远端分支(`git push origin --delete`),会影响远端仓库上的同名分支,调用方需先确认。
    func deleteRemoteBranch(_ branch: String, in directory: String) async throws
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry]
    /// 当前分支领先上游的提交(`git log @{u}..HEAD`);无上游或执行失败时返回空。
    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry]
    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry]
    /// 指定 ref 领先其上游的提交(`<rev>@{u}..<rev>`);ref 无上游或执行失败时返回空。
    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry]
    /// 分页查询提交记录:关键词过滤与 `--skip` 下推到 git,命中范围不限于已加载的首页。
    func commitLogPage(_ request: CommitLogPageRequest) async -> GitCommitLogPage
    /// 远端分支名单;`nil` 表示探测失败(URL 非法/网络失败),空数组是"远端确无分支"。
    /// 调用方据此区分:stale-while-revalidate 的展示方在 nil 时保留旧缓存。
    func remoteBranches(for remoteURL: String) async -> [String]?
    /// Stash 列表(stash@{0} 最新,在前);`nil` = 读取失败,`[]` = 栈为空。
    func stashList(in directory: String) async -> [GitStashEntry]?
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
    /// 两分支间 diff;`head` 为当前分支时含工作区未提交改动。失败(含取消/超时)如实抛错,不吞成空 diff。
    func diffBranches(base: String, head: String, in directory: String) async throws -> [GitDiffEntry]
    /// 两个 ref 的分歧提交数(`rev-list --left-right --count base...head`);ref 非法或执行失败返回 nil。
    func divergence(base: String, head: String, in directory: String) async -> GitRefDivergence?
    /// 指定修订版本中某文件的完整内容(`git cat-file blob`);不存在时返回 nil。
    func blobContent(revision: String, path: String, in directory: String) async -> String?
    /// 全部本地分支元数据(一次 for-each-ref 扫描);`nil` = 读取失败,`[:]` = 没有本地分支。
    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata]?
    /// 单个提交的完整详情;hash 非法或提交不存在时返回 nil。
    func commitDetail(hash: String, in directory: String) async -> GitCommitDetail?
    func createBranch(_ branch: String, fromRev rev: String, in directory: String) async throws
    /// 创建前先 `fetch` 刷新 `origin/<baseBranch>`:分支列表是弹窗打开时的探测快照,
    /// 不刷新可能基于过期提交甚至已删除的引用。
    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws
    /// 丢弃指定文件的全部未提交改动:修改/删除恢复到 HEAD,未跟踪文件直接删除,不可恢复。
    func discardChanges(filePath: String, in directory: String) async throws
    /// 提交工作区全部改动(含 untracked):`git add --all` 后 `git commit -m`。
    func commitAllChanges(message: String, in directory: String) async throws
    /// 中止进行中的合并/变基/cherry-pick/revert/二分并返回该操作;无进行中操作时抛错,二次确认由界面负责。
    func abortInterruptedOperation(in directory: String) async throws -> GitInterruptedOperation
}

extension GitServicing {
    // 协议默认实现:测试替身无需实现这些方法即可编译。
    func remoteTrackingBranches(in directory: String) async -> [String]? { nil }
    func diffWorkingDirectory(in directory: String) async -> [GitDiffEntry] { [] }
    func diffCommit(hash: String, in directory: String) async -> [GitDiffEntry] { [] }
    func diffBranches(base: String, head: String, in directory: String) async -> [GitDiffEntry] { [] }
    func divergence(base: String, head: String, in directory: String) async -> GitRefDivergence? { nil }
    func blobContent(revision: String, path: String, in directory: String) async -> String? { nil }
    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata]? { nil }
    func commitDetail(hash: String, in directory: String) async -> GitCommitDetail? { nil }
    func createBranch(_ branch: String, fromRev rev: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持创建分支")
    }
    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持基于远端分支创建")
    }
    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }
    func stashList(in directory: String) async -> [GitStashEntry]? { nil }
    /// 默认实现无 SHA 追踪(回退弹栈顶);生产 GitService 覆写为可判别"是否真的创建"的版本。
    func trackedStashCreate(in directory: String) async throws -> GitTrackedStash {
        try await stash(in: directory)
        return .created(sha: nil)
    }
    func trackedStashRestore(sha trackedStash: GitTrackedStash, in directory: String) async throws {
        // `.notCreated` 防御性按空操作处理:弹走用户既有 stash 是数据错乱级后果。
        if case .notCreated = trackedStash { return }
        try await stashPop(in: directory)
    }
    // 写/破坏性操作的默认实现必须显式抛错:空 {} 会让忘实现的测试替身假成功,掩盖未实现状态。
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
    // rev 版默认回退 HEAD 查询;生产 GitService 覆写为按 rev 查询。
    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        await recentCommits(in: directory, count: count)
    }
    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        await unpushedCommits(in: directory, count: count)
    }
    /// 默认实现按 skip/count 切片,**不做关键词过滤**(桩无可搜历史);生产 GitService 覆写并下推搜索。
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
        // 分支名单读取失败 → 整份快照作废,口径同 GitService.branchSnapshotInfo。
        guard let branchList = await branches(in: directory) else { return nil }
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

    var hasStats: Bool { filesChanged != nil }
}

struct CommitLogPageRequest: Equatable {
    let directory: String
    /// 搜索关键词;`nil` 或归一后为空不过滤。非空时下推到 git:整条说明、作者、object ID 形态关键词。
    let searchText: String?
    /// 结果级偏移(`--skip`),即上一页已加载的命中数。
    let skip: Int
    /// 页大小;内部多取一条探测是否还有更多。
    let count: Int
    let rev: String?
    let unpushedOnly: Bool
}

struct GitCommitLogPage: Equatable {
    let commits: [GitCommitEntry]
    let hasMore: Bool

    static let empty = GitCommitLogPage(commits: [], hasMore: false)
}

/// 单提交详情:用 `git show -s` 按需取,不进列表日志格式——多行正文(%B)会破坏行解析。
struct GitCommitDetail: Equatable, Sendable {
    let hash: String
    let authorName: String
    let authorEmail: String
    let date: Date?
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

struct GitStashEntry: Identifiable, Equatable, Sendable {
    /// stash 栈位置(stash@{index}),0 为最新。
    let index: Int
    let message: String
    let date: Date
    /// stash 对象 ID(`%H`)。位置是**易变身份**(再 push 一条,同一 stash@{N} 即指向别处),pop/drop
    /// 动手前必须按此 ID 对账,否则误删他人条目且不可恢复;nil = 输出不含该字段,不得当作已核验。
    var objectID: String? = nil

    var id: Int { index }
    var ref: String { "stash@{\(index)}" }

    /// 解析 `git stash list --format=%gs\u{1F}%cI\u{1F}%H` 输出;行序即栈位置。
    static func parseList(_ output: String) -> [GitStashEntry] {
        let fieldSeparator = "\u{1F}"
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        return output.components(separatedBy: .newlines).enumerated().compactMap { lineIndex, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let parts = trimmed.components(separatedBy: fieldSeparator)
            // 消息可合法含 \u{1F},行绝不能丢弃:行序即栈位置,丢一行会使其后所有条目 index 前移,
            // pop/drop 按 index 命中错误 stash(drop 不可恢复)。故按"尾部固定字段+头部可变消息"拆分。
            guard parts.count >= 2 else { return nil }
            // 按"末段是否 40 位十六进制"判新格式,不按段数:消息含分隔符的老行同样有 3 段,
            // 按段数会把它的日期当成 objectID。
            let hasObjectID = parts.count >= 3
                && parts[parts.count - 1].utf8.count == 40
                && GitService.isCommitSHA(parts[parts.count - 1])
            let dateField = hasObjectID ? parts[parts.count - 2] : parts[parts.count - 1]
            let messageEnd = hasObjectID ? 2 : 1
            return GitStashEntry(
                index: lineIndex,
                message: parts.dropLast(messageEnd).joined(separator: fieldSeparator),
                date: dateFormatter.date(from: dateField) ?? .distantPast,
                objectID: hasObjectID ? parts[parts.count - 1] : nil
            )
        }
    }
}

struct GitDiffEntry: Identifiable, Equatable {
    /// 变更后的文件路径(`git diff --numstat` 的第三列)。
    let filePath: String
    /// 新增行数;-1 表示二进制文件。
    let insertions: Int
    /// 删除行数;-1 表示二进制文件。
    let deletions: Int
    let patch: String

    /// 只用 filePath 不够:`git diff -M` 重命名时第三列可为 `a/{old => new}`,两条目撞 id
    /// 会让 ForEach 与按 id 索引的展开状态串号;拼 patch 散列保同批次唯一。
    var id: String { "\(filePath)#\(patch.hashValue)" }

    var isBinary: Bool { insertions < 0 || deletions < 0 }

    var changeType: GitDiffChangeType {
        // `new file mode` / `deleted file mode` / `rename from` 只出现在 diff header 区域,
        // 不应匹配文件内容中恰好包含这些词的行,因此只检查 patch 的前 5 行。
        let headerLines = patch.components(separatedBy: .newlines).prefix(5).joined(separator: "\n")
        if headerLines.contains("new file mode") { return .added }
        if headerLines.contains("deleted file mode") { return .deleted }
        if headerLines.contains("rename from") || headerLines.contains("rename to") { return .renamed }
        return .modified
    }

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
        /// 分支被其它 worktree 检出、本地 fetch 被 git 拒绝——非故障,归入跳过类,避免批量拉取误报"失败"。
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
    /// 未推送提交数(领先 upstream);无 upstream 时为 0。
    let aheadCount: Int
    /// 远端已有而本地未合入的提交数(落后 upstream);无 upstream 时为 0。
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
            // 路径可合法含首尾空格:`u` 行必须用未 trim 的原始行解析,其余行沿用去空白语义。
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

    /// porcelain v2 `u` 行格式(git 2.39 实测):`u <XY> <sub> <mode>×4 <hash>×3 <path>[\t<origPath>]`;
    /// 前 10 个字段不含空格,路径为剩余全部内容(可含空格),rename 冲突原路径以 tab 缀后。
    static func unmergedPath(fromLine line: String) -> String? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11, fields[0] == "u" else { return nil }
        let rawPath = String(fields[10]).components(separatedBy: "\t").first ?? ""
        let path = decodePorcelainPath(rawPath)
        return path.isEmpty ? nil : path
    }

    /// git 对含引号/控制符/非 ASCII(core.quotepath)的路径输出 C 风格引用(`"..."`+转义),普通路径原样。
    static func decodePorcelainPath(_ rawPath: String) -> String {
        guard rawPath.hasPrefix("\""), rawPath.hasSuffix("\""), rawPath.count >= 2 else {
            return rawPath
        }
        let body = rawPath.dropFirst().dropLast()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count)
        // 索引推进而非迭代器:八进制转义提前结束时,迭代器 next() 会吞掉合法后继字符再丢弃。
        // git 恒输出 3 位八进制,此为防御性正确。
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
                // 数字判定限 ASCII 0-9:Unicode isNumber 会放行非 ASCII 数字,误判拼坏转义序列。
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

/// 进行中、可中止的操作:冲突几乎只发生在这些操作中途,中止入口据此选命令与文案。
enum GitInterruptedOperation: String, CaseIterable, Codable, Equatable, Sendable {
    case rebase
    case cherryPick
    case revert
    case merge
    case bisect

    var displayName: String {
        switch self {
        case .rebase: return "变基"
        case .cherryPick: return "拣选"
        case .revert: return "还原"
        case .merge: return "合并"
        case .bisect: return "二分定位"
        }
    }

    var markerNames: [String] {
        switch self {
        case .rebase: return ["rebase-merge", "rebase-apply"]
        case .cherryPick: return ["CHERRY_PICK_HEAD"]
        case .revert: return ["REVERT_HEAD"]
        case .merge: return ["MERGE_HEAD"]
        case .bisect: return ["BISECT_LOG"]
        }
    }

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

struct GitBranchMetadata: Equatable, Sendable {
    let lastCommitDate: Date?
    let aheadCount: Int
    let behindCount: Int
    let upstreamGone: Bool
    /// 是否配置上游(`%(upstream)` 非空)。不能用 track 判:有上游且同步时 track 也是空串。
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
        // 记录自动暂存的结果令牌:body 内含可达 60s 的联网操作,窗口期内用户/其它任务再 `git stash`
        // 会让"弹栈顶"弹到**别人的 stash**——数据错乱级后果,必须拿令牌对账。
        var trackedStash: GitTrackedStash?
        do {
            try await validateCleanWorkingTree(
                in: directory,
                gitService: gitService,
                blockedOperation: blockedOperation
            )
        } catch GitWorktreeSafetyError.uncommittedChanges {
            let token = try await gitService.trackedStashCreate(in: directory)
            // 空转(退出 0)时栈里的条目全是用户既有 stash,绝不能进入恢复路径。
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

    /// 恢复自动暂存必须**脱离当前取消上下文**:body 被 View 取消后,已取消任务里的
    /// `Task.checkCancellation()` 会拒绝执行,暂存将永远回不到工作区;detached 不继承取消,body 取消原样上抛。
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

/// 进程级"remote URL→默认分支"缓存:无 origin/HEAD 时探测走 `ls-remote --symref`,批量操作逐仓库联网会叠加延迟;
/// 只缓存成功结果。失效策略:pull/fetch 等写操作成功后**整体清空**(精确失效需反查 remote URL,不值得;语义安全)。
private final class RemoteDefaultBranchCache: @unchecked Sendable {
    static let shared = RemoteDefaultBranchCache()

    private let lock = NSLock()
    private var branchesByRemoteURL: [String: String] = [:]

    /// 键统一 trim:调用方 trim 口径不一,键不一致会让同一远端反复走 ls-remote 探测。
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
    /// 仅测试用:注入 git 子进程的环境变量(配置隔离,如 `GIT_CONFIG_GLOBAL`),生产恒为 `[:]`。
    /// 带默认值以保住 `GitService()` 既有构造。
    var additionalEnvironment: [String: String] = [:]

    // 并发 `fetch .` 争抢同仓库 packed-refs/index 锁,8 路失败率不降反升;4 是吞吐平衡点。
    private static let maxConcurrentBranchFfTasks = 4

    /// 联网类超时:大仓库/慢网络下一次 fetch 超 60s 会被 SIGTERM 强杀成"失败",统一放宽;
    /// 只有本机探测(ls-remote / for-each-ref)保留 20s 短超时快速失败。
    private static let networkOperationTimeout: TimeInterval = 300

    /// clone 首次抓取整仓历史,比后续 fetch 更重,单列更长超时。
    private static let cloneOperationTimeout: TimeInterval = 600

    func clone(repositoryURL: String, into directory: String) async throws {
        try GitURLParser.validateRemoteURL(repositoryURL)
        let directoryExistedBefore = FileManager.default.fileExists(atPath: directory)
        do {
            try await runGit(arguments: ["clone", "--", repositoryURL, directory], timeout: Self.cloneOperationTimeout)
        } catch {
            // 失败遗留的"半克隆"目录须清:否则 pull 跳过它、重 clone 又因目录已存在永败(死局)。
            // 仅删本次调用前不存在且经 isPartialCloneRemnant 复核(TOCTOU)的;rm -rf 移出主线程防冻结 UI。
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

    /// git clone 先建 `.git` 再 fetch,失败残留必含 `.git` 或为空;非空且无 `.git` 不认领——
    /// 那多半是窗口期内外部进程放入的内容,宁可留残目录也不删用户数据。internal 供单测直接覆盖。
    static func isPartialCloneRemnant(at directory: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        return entries.isEmpty || entries.contains(".git")
    }

    func pull(in directory: String) async throws {
        do {
            try await runGit(arguments: ["-C", directory, "pull"], timeout: Self.networkOperationTimeout)
        } catch let error as GitServiceError where Self.isMissingPullStrategyError(error) {
            // git 2.34+ 在分叉且未配置 pull.rebase/pull.ff 时拒绝 pull,这里回退为显式合并。
            try await runGit(arguments: ["-C", directory, "pull", "--no-rebase"], timeout: Self.networkOperationTimeout)
        }
        RemoteDefaultBranchCache.shared.invalidateAll()
    }

    private static func isMissingPullStrategyError(_ error: GitServiceError) -> Bool {
        error.stderr.lowercased().contains("reconcile divergent branches")
    }

    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome {
        try await runGit(arguments: ["-C", directory, "fetch", "origin"], timeout: Self.networkOperationTimeout)
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
                // rev-parse 失败不能吞成空串:空 SHA 会被误判"不等"而走 fetch 路径,真实原因丢失。
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
                // `fetch .` 以本地仓库为源做纯快进(不联网):非快进与他 worktree 检出分支会被 git 拒,
                // 比 update-ref 安全——不会让其他 worktree 的文件与引用脱节。
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

        // 不用裸 push:它会跟随用户全局 push.default,行为随环境漂移;须显式 remote+分支。
        // `--` 后分支名 git 优先解析为 ref(实测不受同名文件影响),且挡住 `-` 开头名进选项位。
        if let upstream = await trackingBranch(in: directory) {
            // 上游形如 `<remote>/<branch>`;异常前缀(空、以 `-` 开头会被当选项)退回 origin。
            let prefix = upstream.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let remote = (prefix.isEmpty || prefix.hasPrefix("-")) ? "origin" : prefix
            try await runGit(arguments: ["-C", directory, "push", remote, "--", currentBranch], timeout: Self.networkOperationTimeout)
            return
        }

        guard await remoteURL(in: directory) != nil else {
            throw gitOperationError("仓库未配置 origin 远端")
        }

        try await runGit(arguments: ["-C", directory, "push", "-u", "origin", "--", currentBranch], timeout: Self.networkOperationTimeout)
    }

    func stash(in directory: String) async throws {
        try await stashPush(in: directory, message: "CCSpace 临时工作区安全暂存")
    }

    func stashPop(in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "stash", "pop"])
    }

    /// 工作区 diff 展示 untracked 的上限:超出部分不展示但 `commitAllChanges` 仍会提交,
    /// 展示≠提交范围须由界面显式告知。Service 侧单一事实来源,视图引用。
    static let untrackedDisplayLimit = 100

    /// git pathspec 默认 wildmatch:文件名里的 `[ ] ? *` 是合法字符却会被当通配命中**另一个**文件,
    /// `clean -f` 落错文件即不可恢复。展示路径与命令参数分离,命令侧一律加 `:(literal)`。
    static func literalPathspec(_ path: String) -> String { ":(literal)" + path }

    /// 修订名解析失败的实测特征(unborn HEAD 下 `git diff HEAD`:"fatal: ambiguous argument 'HEAD': unknown revision…")。
    /// 只有这类失败才值得用去掉修订名的命令重试。
    static func isUnresolvableRevisionError(_ error: Error) -> Bool {
        guard let gitError = error as? GitServiceError else { return false }
        let lower = gitError.stderr.lowercased()
        return lower.contains("unknown revision")
            || lower.contains("bad revision")
            || lower.contains("does not have any commits")
    }

    /// ASCII 十六进制 object ID(可缩写)。判定限 ASCII:`Character.isHexDigit` 按 Unicode 取值
    /// 会放行阿拉伯-印度数字等非 ASCII 字符,削弱 ref 守卫口径。
    static func isHexObjectID(_ candidate: String, minLength: Int = 7, maxLength: Int = 40) -> Bool {
        guard candidate.count >= minLength, candidate.count <= maxLength else { return false }
        return candidate.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character) || ("A"..."F").contains(character)
        }
    }

    /// 完整 commit SHA(40 位十六进制;未来 object format 也可能是 64 位)。
    static func isCommitSHA(_ candidate: String) -> Bool {
        // ASCII-only 口径见 isHexObjectID 注释;此判定兼作 createBranch(fromRev:)/blobContent 的 ref 守卫。
        guard candidate.count == 40 || candidate.count == 64 else { return false }
        return candidate.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character) || ("A"..."F").contains(character)
        }
    }

    func trackedStashCreate(in directory: String) async throws -> GitTrackedStash {
        // push 无改动时空转仍退出 0(状态检查与 push 竞态):前后数一次栈条目对账,否则记到的是
        // 用户既有 stash 的 SHA,恢复侧会 pop 用户数据。用条目数不用 SHA:"空栈"与"查询失败"同为 nil 会误判 notCreated。
        let countBefore = try await trackedStashEntryCount(in: directory)
        try await stash(in: directory)
        // push 成功后改动已在 stash:此后查询失败/取消不得上抛(调用方会按失败收场,改动孤悬栈中),
        // 一律降级 created(sha: nil) 走弹栈顶兜底恢复。
        let countAfter: Int?
        do {
            countAfter = try await trackedStashEntryCount(in: directory)
        } catch {
            return .created(sha: nil)
        }
        // 计数为 nil 时保守按已新建处理,绝不折成 notCreated(那等于改动留栈还报成功)。
        let created = (countBefore == nil || countAfter == nil) ? true : (countAfter != countBefore)
        guard created else {
            return .notCreated
        }
        let topAfter: String?
        do {
            topAfter = try await trackedStashTopSHA(in: directory)
        } catch {
            return .created(sha: nil)
        }
        return .created(sha: topAfter)
    }

    /// 栈条目数:空栈也是退出 0+空输出,只有 git 真实非 0 失败才 nil——"空栈(0)"与"失败(nil)"可区分。
    /// 取消与进程级错误由 outputIgnoringGitFailure 原样上抛,不折成 nil。
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

    /// 栈顶 commit SHA;空栈(`rev-parse --verify -q` 非 0)、其它失败或输出异常返回 nil。
    private func trackedStashTopSHA(in directory: String) async throws -> String? {
        // 取消原样上抛,不折成"拿不到 SHA":悄悄继续会失去传播,期间又 stash 时恢复侧弹错条目。
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
            // 未创建暂存:恢复必须空操作——栈里条目属于用户,pop 会弹错对象。
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

    func stashList(in directory: String) async -> [GitStashEntry]? {
        let fieldSeparator = "\u{1F}"
        // nil=读取失败、[]=栈空,两态必须可区分:失败折成"栈空"会诱导用户手工 drop,更危险。
        guard let output = await readGitOutput(operation: "stash-list", arguments: [
            "-C", directory,
            // %H 带对象 ID:位置易变,pop/drop 前按 ID 对账(见 GitStashEntry.objectID)。
            "stash", "list", "--format=%gs\(fieldSeparator)%cI\(fieldSeparator)%H",
        ]) else {
            return nil
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
        // 不做 trim:首尾空格是合法文件名,trim 会把丢弃作用到改写后的另一个路径。
        // pathspec 走 literalPathspec:wildmatch 命中错文件 + clean -f 即不可恢复(见其注释)。
        let trimmedPath = filePath
        guard Self.isSafeRepositoryRelativePath(trimmedPath) else {
            throw gitOperationError("文件路径无效，无法丢弃改动")
        }

        switch try await runRawGit(arguments: ["-C", directory, "rev-parse", "--verify", "-q", "HEAD"]) {
        case .exited(0):
            // 先 reset 移出暂存区(对任何状态安全、失败不阻塞),再按 HEAD 有无该文件二选一:checkout 恢复 / clean -f 删除。
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
        // 20s 短超时(与 remoteBranches 同款):ls-remote 类探测弱网快速失败,不让 UI 干等 60s。
        guard let output = await readGitOutput(operation: "default-branch-probe", arguments: [
            "ls-remote", "--symref", remoteURL, "HEAD"
        ], timeout: 20) else {
            return nil
        }
        let branch = Self.parseSymrefDefaultBranch(output: output)
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

    func branches(in directory: String) async -> [String]? {
        // nil/[] 口径见协议:失败折成 [] 会把一次超时渲染成"仓库没有分支"并固化进快照缓存。
        guard let output = await readGitOutput(operation: "branches", arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads",
        ]) else {
            return nil
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

        let branchesOutput: String
        do {
            branchesOutput = try await branchesTask
        } catch {
            logSnapshotReadFailure(error, command: "for-each-ref refs/heads", directory: directory)
            // 名单读取失败 → **整份快照作废**:快照写进详情页缓存(合并口径 fresh ?? previous),
            // 带空名单落笔会把一次 git 超时固化成"仓库没有分支";作废才保留上一轮,真空仓库走成功+空输出不受影响。
            return nil
        }

        let branchList = branchesOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0 != "HEAD" }

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

    /// 快照读取失败留痕:只上报**进程级**失败(超时/输出超限/启动失败),否则 fd 耗尽这类故障无从归因;
    /// git 真实非零退出与任务取消是常态,详情页 30s 轮询 × N 仓库会把它们刷成噪声。
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
        // rev 进 revs 参数、无 `--` 保护:先过 ref 守卫(或为完整 commit SHA)。
        guard Self.isSafeRefName(trimmedRev) || Self.isCommitSHA(trimmedRev) else {
            throw gitOperationError("起始点标识不合法")
        }
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        // 末尾 `--` 防分支名被解析成路径(同 createLocalBranch)。
        try await runGit(arguments: ["-C", directory, "checkout", "-b", branch, trimmedRev, "--"])
    }

    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws {
        let trimmedBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBase.isEmpty == false else {
            throw gitOperationError("远端基线分支不能为空")
        }
        // 基线由 fetchRemoteBranchReference 校验,新分支名是外来输入须先过守卫。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        // 先强制刷新基线的远端跟踪引用:远端列表是弹窗打开时的探测快照,
        // 期间分支可能已更新或被删除——fetch 失败即如实报错,不基于过期引用建分支。
        try await fetchRemoteBranchReference(trimmedBase, in: directory)
        try await runGit(arguments: [
            "-C", directory, "checkout", "-b", branch, "origin/\(trimmedBase)", "--",
        ])
    }

    func commitDetail(hash: String, in directory: String) async -> GitCommitDetail? {
        // 只收十六进制 commit ID:任意字符串不得当 rev 传给 git(ASCII-only 口径见 isHexObjectID)。
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

    func detectInterruptedOperation(in directory: String) async -> GitInterruptedOperation? {
        guard let gitDirectory = await absoluteGitDirectory(in: directory) else { return nil }
        return GitInterruptedOperation.detect(gitDirectoryPath: gitDirectory) { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// worktree 下各分支的 gitdir 不是仓库内 .git,须经 rev-parse --absolute-git-dir 解析。
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

    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata]? {
        guard let output = await readGitOutput(operation: "branch-metadata", arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)%01%(committerdate:unix)%01%(upstream:track)%01%(upstream)",
            "refs/heads",
        ]) else {
            return nil
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
        // `--` 已防选项注入;守卫另挡坏 ref 名报出的英文底层错误,统一转中文提示。
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
        try await runGit(arguments: ["-C", directory, "push", "origin", "--delete", "--", branch], timeout: Self.networkOperationTimeout)
    }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }
        guard let defaultBranch = await defaultBranch(in: directory) else {
            throw gitOperationError("无法识别仓库默认分支")
        }
        // 默认分支值远端可控(origin/HEAD / ls-remote 返回),拼进 fetch/merge 前必须过 ref 守卫:
        // 含空格/选项样式的值会拼出非法甚至有歧义的命令行。
        guard Self.isSafeRefName(defaultBranch) else {
            throw gitOperationError("无法识别仓库默认分支")
        }
        guard currentBranch != defaultBranch else {
            return .skipped
        }

        try await runGit(arguments: ["-C", directory, "fetch", "origin", "--", defaultBranch], timeout: Self.networkOperationTimeout)
        RemoteDefaultBranchCache.shared.invalidateAll()
        try await runGit(arguments: ["-C", directory, "merge", "--no-edit", "--", "origin/\(defaultBranch)"])
        return .merged
    }

    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] {
        await recentCommits(in: directory, count: count, rev: nil)
    }

    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        if let rev, !Self.isSafeRefName(rev) { return [] }
        // 读取失败与"无提交"都返回 []:提交列表空态由 UI 区分(同 unpushedCommits 取舍)。
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
            // 非搜索态:`--skip` 在 git 过滤后生效,是精确结果级游标;每页只取 count+1,翻页不从头重拉。
            let entries = await commitLogEntries(in: request.directory, count: count + 1, skip: skip, range: range, options: [])
            return GitCommitLogPage(commits: Array(entries.prefix(count)), hasMore: entries.count > count)
        }

        // `--grep` 与 `--author` 混用是**与**语义(git 2.54 实测,非直觉的"或"),任一命中只能两路查询取并集。
        // 两路同按作者时间倒序:并集 skip+count 名之前的命中必落在各前缀内,故各取 headCount 条即可。
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
        // 关键词形如 object ID 时补一路直达查询(--grep 匹配不到哈希);
        // "仅看未推送"不做:未推送集合由 range 严格界定,塞入任意可解析对象会破坏筛选语义。
        var lists: [[GitCommitEntry]] = [await messageMatches, await authorMatches]
        if request.unpushedOnly == false, Self.isHexObjectID(searchText, maxLength: 64) {
            lists.append(await commitLogEntries(in: request.directory, count: 1, skip: 0, range: searchText, options: []))
        }
        return Self.mergeCommitLogMatches(lists, skip: skip, count: count)
    }

    private static func commitLogRange(rev: String?, unpushedOnly: Bool) -> String? {
        guard unpushedOnly else { return rev }
        return rev.map { "\($0)@{u}..\($0)" } ?? "@{u}..HEAD"
    }

    /// 归一搜索词:换行折空格(`--grep` 模式串按行匹配,带换行永远落空),去首尾空白,空则 nil 不过滤。
    /// internal:纯函数,供单测覆盖。
    static func normalizedCommitLogSearchText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// `-F` 字面量子串匹配(UI 语义,免 `(`/`[` 被当正则;git 2.54 实测同时作用于 --grep/--author),`-i` 忽略大小写;
    /// `--author-date-order` 把两路结果钉到同一时间键——并集分页窗口才稳定。
    private static func commitLogSearchOptions(pattern: String) -> [String] {
        ["-F", "-i", "--author-date-order", pattern]
    }

    /// 去重后按时间倒序(同刻按哈希定序,保证全序确定、分页窗口稳定),取窗口 [skip, skip+count)。
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

    /// 解析 `git log --format=… --numstat`:format 段与 numstat 段交替输出——含 \x1F 的是元数据行(新记录),
    /// 其余非空行归上一条;字段用 \x1F 分隔避免与提交信息冲突。
    private static func parseCommitLog(_ output: String) -> [GitCommitEntry] {
        let fieldSeparator = "\u{1F}"
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

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
                flushPending()
                let parts = line.components(separatedBy: fieldSeparator)
                // `>= 4`+中段回拼:提交标题可合法含 \u{1F},精确 4 段判定会整条丢弃该记录
                // (同 GitStashEntry.parseList 口径)。
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
            // git diff HEAD 含已暂存+已跟踪改动,但 untracked 不在其中(git 固有行为)。
            let output = try await runGitOutput(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "HEAD", "--numstat", "-p", "--no-color",
                // 封堵仓库自带的可执行程序:.gitattributes + 本地 diff.<driver>.textconv 实测会被 git diff 执行。
                // 不能用 `-c diff.external=` 覆盖:空值让 git 以为外部 diff 已启用并 exec 空命令名,直接 fatal。
                "--no-ext-diff", "--no-textconv",
            ])
            entries = GitDiffParser.parse(output: output)
        } catch {
            // 无 commit 仓库回退为仅未暂存 diff;只在修订名解析不了时回退——
            // 超时/取消/非仓库类失败回退同样会败,却多等一个完整超时。
            guard Self.isUnresolvableRevisionError(error) else { throw error }
            let rawOutput = try await runGitOutput(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "--numstat", "-p", "--no-color",
                "--no-ext-diff", "--no-textconv",
            ])
            entries = GitDiffParser.parse(output: rawOutput)
        }

        // 补 untracked:`git diff --no-index /dev/null <file>` 逐文件生成 diff,有差异时退出 1 属正常;
        // 数量上限见 untrackedDisplayLimit。
        let untracked = await untrackedFiles(in: directory)
        let trackedPaths = Set(entries.map(\.filePath))
        var pending: [(index: Int, file: String)] = []
        for (offset, file) in untracked.prefix(Self.untrackedDisplayLimit).enumerated() where trackedPaths.contains(file) == false {
            pending.append((index: offset, file: file))
        }
        guard pending.isEmpty == false else { return entries }

        // 有界并发(4,同分支拉取平衡点):串行叠加进程启动开销,全量入队会同时拉起上百 git 进程。
        // 按 index 回填保 ls-files 顺序;单文件失败只跳过该文件,取消原样上抛不吞成假静默。
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
                                "--no-ext-diff", "--no-textconv",
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
        // hash 进 revs 位、后面无 `--` 可依赖:`-` 开头串会被 git 当选项(如 --output 写文件,甚至触发外部命令);
        // 先守卫再加 --end-of-options。守卫拒绝须抛错:[] 与"该提交无改动"不可区分,静默=语义错误的空 diff。
        guard Self.isHexObjectID(hash, maxLength: 64) || Self.isCommitSHA(hash) else {
            throw gitOperationError("提交标识非法，无法读取其改动")
        }
        // `--first-parent`:merge commit 的 show -p 默认 combined diff——干净合并时 patch 为空而
        // --numstat 仍按第一父统计,出现"文件列表有、diff 内容为空";统一按第一父取 diff 保一致(失败如实抛错)。
        let output = try await runGitOutput(
            arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "show", "--first-parent", "--numstat", "-p", "--no-color",
                "--no-ext-diff", "--no-textconv",
                "--format=", "--end-of-options", hash,
            ],
            allowedExitCodes: [0, 1]
        )
        return GitDiffParser.parse(output: output)
    }

    /// revision/path 都必须过守卫:任意字符串可读仓库内任意 blob(如 .git 配置对象);
    /// 路径不存在/子模块(commit 对象)时 `try?` 回退 nil,按不展开处理。
    func blobContent(revision: String, path: String, in directory: String) async -> String? {
        guard Self.isSafeRefName(revision) || Self.isCommitSHA(revision) else { return nil }
        guard Self.isSafeRepositoryRelativePath(path) else { return nil }
        return await readGitOutput(operation: "blob-content", arguments: [
            "-C", directory, "cat-file", "blob", "\(revision):\(path)",
        ])
    }

    /// 提交全部改动:`git add --all` 范围与 diffWorkingDirectory 展示一致;
    /// commit 失败(如未配置 user.name/email)时改动留暂存区,补齐后重试即可(add 幂等)。
    func commitAllChanges(message: String, in directory: String) async throws {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedMessage.isEmpty == false else {
            throw gitOperationError("提交信息不能为空")
        }
        try await runGit(arguments: ["-C", directory, "add", "--all"])
        try await runGit(arguments: ["-C", directory, "commit", "-m", trimmedMessage])
    }

    /// `head` 为当前分支时改比工作区(含未提交改动),与"未提交"提示一致;两非当前分支按提交对比。
    func diffBranches(base: String, head: String, in directory: String) async throws -> [GitDiffEntry] {
        // revs 参数无 `--` 保护先过守卫;拒绝须抛错:[] 与"两分支无差异"不可区分(同 diffCommit 口径)。
        guard Self.isSafeRefName(base), Self.isSafeRefName(head) else {
            throw gitOperationError("分支名称非法，无法比较改动")
        }
        let currentBranch = await currentBranch(in: directory)
        let range = (head == currentBranch) ? base : "\(base)..\(head)"
        // `git diff` 有差异时退出码 1 属正常;`-c core.quotepath=false` 让非 ASCII 路径按 UTF-8 原样输出。
        let output = try await runGitOutput(
            arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "--numstat", "-p", "--no-color", range,
                "--no-ext-diff", "--no-textconv",
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
        // ref 列表探测 20s 快速失败(弹窗提供重试),不让弱网用户干等 60s;
        // 失败返回 nil 而非 []:与"远端确无分支"必须可区分,否则一次抖动就覆盖掉可用的旧名单。
        guard let output = await readGitOutput(operation: "remote-branches", arguments: [
            "ls-remote", "--heads", remoteURL
        ], timeout: 20) else { return nil }

        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.components(separatedBy: "\t")
                guard parts.count == 2 else { return nil }
                let ref = parts[1]
                let prefix = "refs/heads/"
                guard ref.hasPrefix(prefix) else { return nil }
                return String(ref.dropFirst(prefix.count))
            }
    }

    /// ls-remote 只请求 HEAD,全量名单是 `remoteBranches`(`--heads`)的职责。internal:纯函数,供单测覆盖。
    static func parseSymrefDefaultBranch(output: String) -> String? {
        let headsPrefix = "refs/heads/"
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("ref:") else { continue }
            // 形如 `ref: refs/heads/main\tHEAD`:先按 tab 切断尾部,再取指向。
            let firstField = trimmed.split(separator: "\t", maxSplits: 1).first ?? ""
            let target = firstField.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            guard target.hasPrefix(headsPrefix) else { continue }
            let name = String(target.dropFirst(headsPrefix.count))
            if name.isEmpty == false { return name }
        }
        return nil
    }

    /// 本地已有的远端跟踪分支;只读本地引用不联网,排除 origin/HEAD 这类符号引用。
    func remoteTrackingBranches(in directory: String) async -> [String]? {
        guard let output = await readGitOutput(operation: "remote-tracking-branches", arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/remotes",
        ]) else {
            return nil
        }
        // origin/HEAD 的 refname:short 是裸 "origin",统一按"必须含 /"过滤掉。
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("/") }
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

    /// `.git/config` 属仓库自带数据(磁盘导入的远端不可控),过不了守卫的名字直接跳过——它们要拼进引用路径。
    private func remoteNames(in directory: String) async -> [String] {
        guard let output = await readGitOutput(
            operation: "remote-list",
            arguments: ["-C", directory, "remote"]
        ) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && Self.isSafeRefName($0) }
    }

    private static func preferredRemoteOrder(_ remotes: [String]) -> [String] {
        guard let originIndex = remotes.firstIndex(of: "origin"), originIndex != 0 else {
            return remotes
        }
        var ordered = remotes
        ordered.remove(at: originIndex)
        ordered.insert("origin", at: 0)
        return ordered
    }

    private func hasRemoteTrackingReference(
        remote: String,
        branch: String,
        in directory: String
    ) async -> Bool {
        guard let output = await readGitOutput(
            operation: "remote-ref-exists",
            arguments: ["-C", directory, "rev-parse", "--verify", "-q", "--", "refs/remotes/\(remote)/\(branch)"]
        ) else {
            return false
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func checkoutTrackingBranch(
        _ branch: String,
        remote: String,
        in directory: String
    ) async throws {
        try await runGit(arguments: [
            "-C", directory,
            "checkout",
            "--track",
            "\(remote)/\(branch)",
        ])
    }

    /// 本地没有同名分支时,改跟踪**任一**远端的同名分支:只认 origin 会让远端改名/用别名
    /// 的仓库查不到已有分支,静默兜底 `checkout -b` 建出一个当前代码的同名分支(数据错拿级)。
    private func checkoutRemoteTrackingBranchIfAvailable(
        _ branch: String,
        in directory: String
    ) async throws -> Bool {
        let remotes = Self.preferredRemoteOrder(await remoteNames(in: directory))
        guard remotes.isEmpty == false else {
            return false
        }

        // 先查已有的远端跟踪引用:零网络,且覆盖 fetch 过但引用未清理的正常场景。
        for remote in remotes {
            guard await hasRemoteTrackingReference(remote: remote, branch: branch, in: directory) else {
                continue
            }
            do {
                try await checkoutTrackingBranch(branch, remote: remote, in: directory)
                return true
            } catch {
                // 引用明明存在却切不过去(工作树冲突等)必须照抛:
                // 按"分支不存在"收场会让调用方去新建同名分支,把真实故障盖掉。
                if isMissingRemoteBranchError(error) { continue }
                throw error
            }
        }

        // 取舍:分支不存在时最坏 N 次网络往返(N=远端数,通常为 1),换"非 origin 远端分支不被静默新建"。
        for remote in remotes {
            do {
                try await fetchRemoteBranchReference(branch, remote: remote, in: directory)
                try await checkoutTrackingBranch(branch, remote: remote, in: directory)
                return true
            } catch {
                if isMissingRemoteBranchError(error) { continue }
                throw error
            }
        }
        return false
    }

    private func fetchRemoteBranchReference(
        _ branch: String,
        remote: String = "origin",
        in directory: String
    ) async throws {
        // branch 拼进 refspec、无 `--` 可加,外来名先过守卫。
        guard Self.isSafeRefName(branch) else {
            throw gitOperationError("分支名不合法：\(branch)")
        }
        try await runGit(arguments: [
            "-C", directory,
            "fetch",
            remote,
            // refspec 必须带 `+` 强制更新:不带时 force-push 过的远端值会被 non-fast-forward 拒绝,
            // 而这正是"fetch 刷新过期引用"最该覆盖的场景;更新跟踪引用无风险。
            "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)",
        ], timeout: Self.networkOperationTimeout)
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

    /// 本地分支切不过去、应走"跟踪远端/自动建分支"兜底的报错特征。
    /// 只匹配 git 对无效 rev 的精确文案:宽匹配会把其它失败误判成"分支不存在"而兜底新建,掩盖真实故障。
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

    /// 只在 git **真实非 0 失败**时降级 nil 的探测读取;超时/输出超限/启动失败/取消必须原样上抛——
    /// 折成 nil 会退化成误判(抛出与事实无关的"Stash 栈已被改动"),吞掉的取消还会失去传播。
    private func outputIgnoringGitFailure(arguments: [String]) async throws -> String? {
        do {
            return try await runGitOutput(arguments: arguments)
        } catch is GitServiceError {
            // 进程级错误都不是 GitServiceError,走到这里只可能是 git 真实退出码非 0。
            return nil
        }
    }

    /// 只读查询容错入口:与 `try?` 吞错等价,但失败必须留痕(命令名+原因),否则现场无从归因。
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

    /// 允许指定退出码的版本(用于 `git diff --no-index` 这类有差异时退出码非 0 的命令)。
    private func runGitOutput(arguments: [String], allowedExitCodes: Set<Int32>, timeout: TimeInterval = 60) async throws -> String {
        let result = try await runProcess(arguments: arguments, captureStdout: true, captureStderr: true, timeout: timeout)
        guard allowedExitCodes.contains(result.terminationStatus) else {
            let stderrMessage = GitServiceError.sanitizedStderr(
                Self.decodedOutput(result.stderrData)
            )
            throw GitServiceError.commandFailed(
                stderr: stderrMessage
            )
        }
        return Self.decodedOutput(result.stdoutData)
    }

    /// git 输出可能含非法 UTF-8(典型:core.quotepath=false 时的非 UTF-8 文件名)。
    /// 直接 `?? ""` 会把整段错误退化成空串丢失真实原因,故有损解码保住可读部分。internal:纯函数供单测。
    static func decodedOutput(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// 守卫会被拼进 `base..head`、`revision:path` 这类**无法加 `--`** 的 revs 参数的外来值:
    /// `-` 开头变选项,空白/换行/NUL 注入 argv,`..`/`@{`/`:` 改写 range 或 object 分隔语义。internal 供单测。
    static func isSafeRefName(_ ref: String) -> Bool {
        guard ref.isEmpty == false, ref.hasPrefix("-") == false else { return false }
        if ref.contains("..") || ref.contains("@{") || ref.contains(":") { return false }
        for scalar in ref.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return false } // 控制字符/NUL
            if Character(scalar).isWhitespace || Character(scalar).isNewline { return false }
        }
        return true
    }

    /// 拒绝绝对路径与向上穿越的 `..`;按**组件**判断,否则 `file..txt` 这类合法文件名会被误拒。internal 供单测。
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
