import Foundation

enum GitServiceError: LocalizedError, Sendable {
    case commandFailed(exitCode: Int32, stderr: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(_, let stderr):
            return stderr.isEmpty ? "git 执行失败" : Self.localizeMessage(stderr)
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
    /// 未匹配到已知模式的错误会保留原始消息。
    private static func localizeMessage(_ stderr: String) -> String {
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

        return redactCredentials(in: stderr)
    }

    /// 匹配 `scheme://user:password@host` 或 `scheme://token@host` 形式的凭据片段。
    /// git 失败时 stderr 普遍会回显整个远端 URL,而用户常把 token 写进 URL
    /// (`https://oauth2:<token>@git.example.com/o/r.git`,或 GitHub 的
    /// `https://ghp_xxx@github.com/o/r.git` —— 用户名即 token,没有冒号段)。
    /// 密码段允许 `/`(base64/URL 风格密钥常见含斜杠),用户名段不允许——
    /// 无凭据的 `https://host/path` 因"首个 @ 前出现斜杠"不会被误脱敏。
    private static let credentialPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "[A-Za-z][A-Za-z0-9+.\\-]*://[^/\\s:@]+(?::[^\\s@]+)?@",
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

protocol GitServicing: Sendable {
    func clone(repositoryURL: String, into directory: String) async throws
    func pull(in directory: String) async throws
    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome
    func push(in directory: String) async throws
    func stash(in directory: String) async throws
    func stashPop(in directory: String) async throws
    /// 暂存当前改动(含 untracked)并返回新建 `stash@{0}` 的 commit SHA。
    /// 返回 nil 表示实现无法提供可回查标识(调用方回退旧的"弹栈顶"语义)。
    func trackedStashCreate(in directory: String) async throws -> String?
    /// 恢复 `trackedStashCreate` 创建的暂存:先校验栈顶仍是该 SHA;
    /// 若被并发操作打乱,则按 SHA 找到对应条目 apply(**不 drop**,错位时的索引已不可信)。
    /// sha 传 nil 回退 `stashPop`。
    func trackedStashRestore(sha: String?, in directory: String) async throws
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
    func remoteBranches(for remoteURL: String) async -> [String]
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
    func createBranch(_ branch: String, fromRev rev: String, in directory: String) async throws {}
    func createBranch(fromRemoteBranch branch: String, baseBranch: String, in directory: String) async throws {
        throw GitServiceError.operationFailed(message: "当前实现不支持基于远端分支创建")
    }
    func gitEnvironmentInfo() async -> GitEnvironmentInfo {
        GitEnvironmentInfo(isAvailable: false, version: nil, executablePath: nil)
    }
    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }
    func stashList(in directory: String) async -> [GitStashEntry] { [] }
    /// 默认实现委托旧接口:测试替身无需感知 SHA 语义即可编译;
    /// 生产 GitService 覆写为 SHA 可回查版本。
    func trackedStashCreate(in directory: String) async throws -> String? {
        try await stash(in: directory)
        return nil
    }
    func trackedStashRestore(sha: String?, in directory: String) async throws {
        try await stashPop(in: directory)
    }
    func stashPush(in directory: String, message: String) async throws {}
    func popStash(at index: Int, in directory: String) async throws {}
    func dropStash(at index: Int, in directory: String) async throws {}
    func discardChanges(filePath: String, in directory: String) async throws {}
    func commitAllChanges(message: String, in directory: String) async throws {}
    func deleteLocalBranch(_ branch: String, in directory: String) async throws {}
    func deleteRemoteBranch(_ branch: String, in directory: String) async throws {}
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
    func probeRemoteInfo(for remoteURL: String) async -> (branches: [String], defaultBranch: String?) {
        async let branchesTask = remoteBranches(for: remoteURL)
        async let defaultBranchTask = defaultBranch(for: remoteURL)
        return await (branchesTask, defaultBranchTask)
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
            guard parts.count == 2 else { return nil }
            return GitStashEntry(
                index: lineIndex,
                message: parts[0],
                date: dateFormatter.date(from: parts[1]) ?? .distantPast
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
        var iterator = body.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                continue
            }
            guard let escaped = iterator.next() else {
                // 结尾裸反斜杠:按字面量保留,不丢内容。
                bytes.append(UInt8(ascii: "\\"))
                continue
            }
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
            case let digit where digit.isNumber:
                // 八进制 \NNN(N 最多 3 位,首字符已由 git 保证非 0 开头的合法编码)。
                var digits = String(digit)
                while digits.count < 3, let next = iterator.next(), next.isNumber {
                    digits.append(next)
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
        // 记录自动暂存条目的 SHA:body 内含 fetch/merge 等可达 60s 的联网操作,
        // 窗口期内用户或其它任务的 `git stash` 会让"弹栈顶"(stash@{0})弹到**别人的
        // stash**——错内容进工作区、真目标滞留栈里,属数据错乱级后果。
        var stashedSHA: String?
        var didStash = false
        do {
            try await validateCleanWorkingTree(
                in: directory,
                gitService: gitService,
                blockedOperation: blockedOperation
            )
        } catch GitWorktreeSafetyError.uncommittedChanges {
            stashedSHA = try await gitService.trackedStashCreate(in: directory)
            didStash = true
        }

        do {
            try await body()
        } catch let operationError {
            if didStash {
                do {
                    try await gitService.trackedStashRestore(sha: stashedSHA, in: directory)
                } catch let restoreError {
                    throw GitWorktreeSafetyError.operationAndStashRestoreFailed(
                        operationReason: operationError.localizedDescription,
                        restoreReason: restoreError.localizedDescription
                    )
                }
            }
            throw operationError
        }

        if didStash {
            do {
                try await gitService.trackedStashRestore(sha: stashedSHA, in: directory)
            } catch {
                throw GitWorktreeSafetyError.stashRestoreFailed(
                    reason: error.localizedDescription
                )
            }
        }
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

struct GitService: GitServicing {
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
            if !directoryExistedBefore {
                let path = directory
                await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(atPath: path)
                }.value
            }
            throw error
        }
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
                currentBranchOutcome = GitBranchPullOutcome(branch: current, status: .failed, errorMessage: e.localizedDescription)
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
            return GitBranchPullOutcome(branch: branch, status: .failed, errorMessage: error.localizedDescription)
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
                return GitBranchPullOutcome(branch: branch, status: .failed, errorMessage: error.localizedDescription)
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
                return GitBranchPullOutcome(branch: branch, status: .failed, errorMessage: error.localizedDescription)
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
            return .crashed(error.localizedDescription)
        }
    }

    func push(in directory: String) async throws {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }

        if await trackingBranch(in: directory) != nil {
            try await runGit(arguments: ["-C", directory, "push"])
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

    /// 完整 commit SHA(40 位十六进制;未来 object format 也可能是 64 位)。
    static func isCommitSHA(_ candidate: String) -> Bool {
        (candidate.count == 40 || candidate.count == 64) && candidate.allSatisfy(\.isHexDigit)
    }

    func trackedStashCreate(in directory: String) async throws -> String? {
        try await stash(in: directory)
        let sha = try? await runGitOutput(arguments: [
            "-C", directory, "rev-parse", "--verify", "stash@{0}",
        ])
        let trimmed = sha?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // rev-parse 异常(仓库竞态删除等)时退回无标识恢复,与旧行为等价,不因追踪失败而丢暂存。
        return Self.isCommitSHA(trimmed) ? trimmed : nil
    }

    func trackedStashRestore(sha: String?, in directory: String) async throws {
        guard let sha, Self.isCommitSHA(sha) else {
            try await stashPop(in: directory)
            return
        }
        let top = try? await runGitOutput(arguments: [
            "-C", directory, "rev-parse", "--verify", "stash@{0}",
        ])
        let topSHA = top?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if topSHA == sha.lowercased() {
            try await stashPop(in: directory)
            return
        }
        // 栈被并发 stash 打乱:按 SHA 定位真实条目,apply 后**保留**该条——
        // 此时索引随时会漂移,drop 误删别人 stash 的代价远大于留一条冗余记录。
        let listOutput = try? await runGitOutput(arguments: [
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
        guard let output = try? await runGitOutput(arguments: [
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
        let trimmedPath = filePath
        guard Self.isSafeRepositoryRelativePath(trimmedPath) else {
            throw gitOperationError("文件路径无效，无法丢弃改动")
        }

        switch try await runRawGit(arguments: ["-C", directory, "rev-parse", "--verify", "-q", "HEAD"]) {
        case .exited(0):
            // 先把该路径移出暂存区,再按 HEAD 是否含该文件二选一:
            // 有则恢复内容(覆盖暂存+未暂存改动),无则按未跟踪文件删除。
            // reset 对各种文件状态均安全,失败不阻塞后续判断。
            try? await runGit(arguments: ["-C", directory, "reset", "-q", "HEAD", "--", trimmedPath])
            switch try await runRawGit(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "cat-file", "-e", "HEAD:\(trimmedPath)",
            ]) {
            case .exited(0):
                try await runGit(arguments: [
                    "-c", "core.quotepath=false",
                    "-C", directory, "checkout", "HEAD", "--", trimmedPath,
                ])
            case .exited:
                try await runGit(arguments: [
                    "-c", "core.quotepath=false",
                    "-C", directory, "clean", "-f", "--", trimmedPath,
                ])
            case .crashed(let message):
                throw gitOperationError(message)
            }
        case .exited:
            // 无提交的仓库(unborn HEAD):所有文件都视同未跟踪,直接删除。
            try await runGit(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "clean", "-f", "--", trimmedPath,
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
        guard let output = try? await runGitOutput(
            arguments: ["ls-remote", "--symref", remoteURL, "HEAD"],
            timeout: 20
        ) else {
            return nil
        }
        let branch = Self.parseSymrefLsRemote(output: output).defaultBranch
        if let branch {
            RemoteDefaultBranchCache.shared.store(branch, for: remoteURL)
        }
        return branch
    }

    func defaultBranch(in directory: String) async -> String? {
        if let output = try? await runGitOutput(arguments: [
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
        guard let output = try? await runGitOutput(arguments: ["-C", directory, "branch", "--show-current"]) else {
            return nil
        }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        guard let output = try? await runGitOutput(arguments: [
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
        guard let output = try? await runGitOutput(arguments: [
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

        guard let statusOutput = try? await statusTask else { return nil }
        var status = GitBranchStatusSnapshot.parsePorcelainV2(statusOutput)

        let branchList: [String]
        if let branchesOutput = try? await branchesTask {
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
        guard hash.count >= 7, hash.count <= 40, hash.allSatisfy(\.isHexDigit) else {
            return nil
        }
        guard let output = try? await runGitOutput(arguments: [
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
        guard let output = try? await runGitOutput(arguments: [
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
        guard let output = try? await runGitOutput(arguments: [
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
        guard let output = try? await runGitOutput(arguments: ["-C", directory, "remote", "get-url", "origin"]) else {
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
        do {
            try await runGit(arguments: ["-C", directory, "branch", "-d", "--", branch])
        } catch {
            guard Self.isBranchNotFullyMergedError(error) else { throw error }
            try await runGit(arguments: ["-C", directory, "branch", "-D", "--", branch])
        }
    }

    func deleteRemoteBranch(_ branch: String, in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "push", "origin", "--delete", "--", branch])
    }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }
        guard let defaultBranch = await defaultBranch(in: directory) else {
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
        guard let output = await commitLogOutput(in: directory, count: count, range: rev) else {
            return []
        }
        return Self.parseCommitLog(output)
    }

    func unpushedCommits(in directory: String, count: Int) async -> [GitCommitEntry] {
        await unpushedCommits(in: directory, count: count, rev: nil)
    }

    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        if let rev, !Self.isSafeRefName(rev) { return [] }
        // 无上游分支时 `@{u}` 解析失败,返回空;调用方以 hasRemoteTrackingBranch 区分展示。
        let range = rev.map { "\($0)@{u}..\($0)" } ?? "@{u}..HEAD"
        guard let output = await commitLogOutput(in: directory, count: count, range: range) else {
            return []
        }
        return Self.parseCommitLog(output)
    }

    /// 执行 `git log` 并返回原始输出;`range` 为可选的提交范围(如 "@{u}..HEAD")。
    private func commitLogOutput(in directory: String, count: Int, range: String?) async -> String? {
        // 钳制到至少 1:count <= 0 会拼出 `git log -0`,git 直接报错。
        let clampedCount = max(1, count)
        let fieldSeparator = "\u{1F}"
        let format = "%H\(fieldSeparator)%s\(fieldSeparator)%an\(fieldSeparator)%aI"
        var arguments = [
            "-C", directory,
            "log",
            "--format=\(format)",
            "--numstat",
            "-\(clampedCount)",
        ]
        if let range {
            // 注意:rev range 必须直接作为 revs 参数,不能放在 `--` 之后(`--` 后是路径语义)。
            arguments.append(range)
        }
        return try? await runGitOutput(arguments: arguments)
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
                guard parts.count == 4 else { continue }
                pendingMeta = (
                    hash: parts[0],
                    subject: parts[1],
                    author: parts[2],
                    date: dateFormatter.date(from: parts[3]) ?? .distantPast
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
            // 只在失败时回退:干净仓库成功且输出为空,不必白跑第二个 git 进程。
            // 回退仍失败则如实上抛(取消/非仓库等),不吞成空 diff。
            let rawOutput = try await runGitOutput(arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "diff", "--numstat", "-p", "--no-color",
            ])
            entries = GitDiffParser.parse(output: rawOutput)
        }

        // 补充 untracked 文件:`git diff --no-index /dev/null <file>` 为每个新文件生成 diff。
        // 该命令有差异时退出码为 1,属正常行为。限制最多处理 100 个文件,避免过多时卡顿。
        let untracked = await untrackedFiles(in: directory)
        let untrackedLimit = 100
        for file in untracked.prefix(untrackedLimit) where entries.contains(where: { $0.filePath == file }) == false {
            if let patch = try? await runGitOutput(
                arguments: [
                    "-c", "core.quotepath=false",
                    "-C", directory, "diff", "--no-index", "--numstat", "-p", "--no-color",
                    "--", "/dev/null", file,
                ],
                allowedExitCodes: [0, 1]
            ) {
                entries.append(contentsOf: GitDiffParser.parse(output: patch))
            }
        }

        return entries
    }

    /// 列出工作区中未跟踪的文件(排除 .gitignore 命中的文件)。
    private func untrackedFiles(in directory: String) async -> [String] {
        guard let output = try? await runGitOutput(arguments: [
            "-c", "core.quotepath=false",
            "-C", directory, "ls-files", "--others", "--exclude-standard",
        ]) else {
            return []
        }
        return output
            .components(separatedBy: "\n")
            // 只剥 CRLF 残留的 \r:文件名首尾空格在 macOS 上合法,
            // trimmingCharacters(.whitespacesAndNewlines) 会把 "mydir /note .txt"
            // 这类真实名字改写,导致下游 --no-index diff 静默失败。
            .map { line in line.hasSuffix("\r") ? String(line.dropLast()) : line }
            .filter { $0.isEmpty == false }
    }

    func diffCommit(hash: String, in directory: String) async throws -> [GitDiffEntry] {
        // `--first-parent`:merge commit 的 `git show -p` 默认走 combined diff,
        // 干净合并时 patch 为空,而 `--numstat` 仍按第一父提交统计,
        // 会出现"文件列表有、diff 内容为空";统一按第一父提交取 diff 保证两者一致。
        // hash 非法/引用缺失/取消等失败如实抛错,不再被 `try?` 吞成"两侧内容完全一致"。
        let output = try await runGitOutput(
            arguments: [
                "-c", "core.quotepath=false",
                "-C", directory, "show", "--first-parent", "--numstat", "-p", "--no-color", "--format=", hash,
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
        return try? await runGitOutput(arguments: [
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
        guard Self.isSafeRefName(base), Self.isSafeRefName(head) else { return [] }
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
        guard let output = try? await runGitOutput(arguments: [
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

    func remoteBranches(for remoteURL: String) async -> [String] {
        guard (try? GitURLParser.validateRemoteURL(remoteURL)) != nil else { return [] }
        // 分支弹窗远端页签的实时名单:网络不通/慢时按默认 60s 干等,
        // 用户体感就是"卡死";ref 列表探测 20s 未响应即按失败处理,
        // 弹窗内提供重试/刷新入口,不再阻塞等待。
        guard let output = try? await runGitOutput(arguments: [
            "ls-remote", "--heads", remoteURL
        ], timeout: 20) else { return [] }

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
        guard let output = try? await runGitOutput(arguments: [
            "ls-remote", "--symref", remoteURL, "HEAD", "refs/heads/*",
        // 表单远端探测是最该快失败的路径:与 remoteBranches 统一 20s(此前 60s,弱网干等)。
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
        guard let output = try? await runGitOutput(arguments: [
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
        let version = (try? await runGitOutput(arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitEnvironmentInfo(
            isAvailable: version?.isEmpty == false,
            version: version?.isEmpty == false ? version : nil,
            executablePath: GitProcessRunner.gitExecutablePath
        )
    }

    private func trackingBranch(in directory: String) async -> String? {
        guard let output = try? await runGitOutput(arguments: [
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
            timeout: timeout
        )
    }

    private func gitOperationError(_ message: String) -> GitServiceError {
        .operationFailed(message: message)
    }
}
