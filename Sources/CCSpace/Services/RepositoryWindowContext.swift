import Foundation

/// 独立窗口(分支比较 / 提交记录)共用的仓库数据加载器:View 不直接调 git。
///
/// 分支名单/远端跟踪分支/当前分支/默认分支的并发取数、分支比较 diff、提交列表分页,
/// 连同「取消 + 代际号」防过期写回的编排都收在本类型——同一套代际模式此前在
/// BranchCompareWindowView 与 CommitLogWindowView 里各写了一遍,现收敛为单一实现。
/// 窗口经 `@StateObject` 持有本类型,只保留展示状态并在完成回调里落笔。
@MainActor
final class RepositoryWindowContext: ObservableObject {
    private let gitService: GitServicing

    private var contextTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    /// 各加载通道的代际号:每次发起递增,旧任务写回前比对,
    /// 防止「isCancelled 检查通过但落笔晚于新任务」造成旧结果覆盖新结果。
    private var contextRequestID = 0
    private var diffRequestID = 0
    private var logRequestID = 0

    init(gitService: GitServicing) {
        self.gitService = gitService
    }

    /// 窗口消失时统一取消在途加载,避免迟到写回。
    func cancelAll() {
        contextTask?.cancel()
        contextTask = nil
        diffTask?.cancel()
        diffTask = nil
        logTask?.cancel()
        logTask = nil
    }

    /// 仅作废在途的 diff 加载(取消 + 递增代际),不动分支上下文加载。
    /// 供「比较侧尚未就绪就触发 reloadDiff」的早退路径:早退也要作废旧任务,
    /// 否则窄窗口内旧任务的迟到写回仍可能落笔。
    func invalidateDiffLoads() {
        diffTask?.cancel()
        diffTask = nil
        diffRequestID += 1
    }

    // MARK: - 分支上下文

    /// 一次分支上下文取数的快照,由窗口在完成回调里消费。
    struct BranchContextSnapshot {
        let branches: [String]
        let remoteTrackingBranches: [String]
        let currentBranch: String?
        let defaultBranch: String?
        /// 全部本地分支元数据;仅提交记录窗口需要,不需要时为 nil(省一次 for-each-ref 扫描)。
        let metadata: [String: GitBranchMetadata]?
    }

    /// 并发加载分支上下文;完成回调在主线程且仅当本请求未被更新的请求取代时触发。
    func loadBranchContext(
        directory: String,
        includeMetadata: Bool,
        completion: @escaping @MainActor (BranchContextSnapshot) -> Void
    ) {
        contextTask?.cancel()
        contextRequestID += 1
        let requestID = contextRequestID
        let service = gitService
        contextTask = Task {
            async let branchesTask = service.branches(in: directory)
            async let remoteTask = service.remoteTrackingBranches(in: directory)
            async let currentTask = service.currentBranch(in: directory)
            async let defaultTask = service.defaultBranch(in: directory)
            let metadata: [String: GitBranchMetadata]?
            if includeMetadata {
                async let metadataTask = service.branchMetadata(in: directory)
                metadata = await metadataTask
            } else {
                metadata = nil
            }
            let branches = await branchesTask
            let remote = await remoteTask
            let current = await currentTask
            let defaultBranch = await defaultTask
            // isCancelled 检查与新任务发起之间仍可能隔着一次挂起:
            // 落笔前再比对代际号,旧一代结果直接作废。
            guard !Task.isCancelled, requestID == contextRequestID else { return }
            completion(BranchContextSnapshot(
                branches: branches,
                remoteTrackingBranches: remote,
                currentBranch: current,
                defaultBranch: defaultBranch,
                metadata: metadata
            ))
        }
    }

    // MARK: - 分支比较 diff

    /// 分支比较 diff 的加载结果:成功携带 entries 与分歧统计;失败带用户文案;
    /// 取消(窗口关闭/payload 更换)不算失败,completion 根本不被调用,静默忽略。
    enum DiffLoadOutcome {
        case success(entries: [GitDiffEntry], divergence: GitRefDivergence?)
        case failure(message: String)
    }

    /// 加载 base → head 的 diff 与分歧统计;与 loadBranchContext 同一代际防过期写回。
    func loadCompareDiff(
        directory: String,
        base: String,
        head: String,
        completion: @escaping @MainActor (DiffLoadOutcome) -> Void
    ) {
        diffTask?.cancel()
        diffRequestID += 1
        let requestID = diffRequestID
        let service = gitService
        diffTask = Task {
            let outcome: DiffLoadOutcome
            do {
                let entries = try await service.diffBranches(base: base, head: head, in: directory)
                let divergenceResult = await service.divergence(base: base, head: head, in: directory)
                outcome = .success(entries: entries, divergence: divergenceResult)
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(message: Self.localizedDiffFailureMessage(error))
            }
            guard !Task.isCancelled, requestID == diffRequestID else { return }
            completion(outcome)
        }
    }

    // MARK: - 提交列表

    /// 提交列表的加载结果:目录缺失是硬失败,单独成案给明确报错而非静默空列表。
    enum CommitLogLoadOutcome {
        case success(commits: [GitCommitEntry], hasMore: Bool)
        case directoryMissing(String)
    }

    /// 按分页参数加载一页提交列表(全量 / 仅未推送,可带关键词搜索)。
    /// 关键词过滤与偏移都由 `commitLogPage` 下推给 git,本类只负责目录探测与代际防过期写回。
    func loadCommits(
        request: CommitLogPageRequest,
        completion: @escaping @MainActor (CommitLogLoadOutcome) -> Void
    ) {
        logTask?.cancel()
        logRequestID += 1
        let requestID = logRequestID
        let service = gitService
        logTask = Task {
            // 目录缺失(工作区被外部删除等)是硬失败。代际已在入口递增:
            // 即使早退,在途旧任务的写回也已被拦下。
            // 探测走 Task.detached:外置盘/网盘的 stat 可达数百毫秒,本类是
            // @MainActor,Task{} 会继承主线程、Task.detached 才真正离开
            // (与项目内"fileExists 必须移出主线程"的既有约定对齐)。
            let directory = request.directory
            let directoryExists: Bool = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: directory)
            }.value
            guard directoryExists else {
                guard !Task.isCancelled, requestID == logRequestID else { return }
                completion(.directoryMissing(directory))
                return
            }
            let page = await service.commitLogPage(request)
            guard !Task.isCancelled, requestID == logRequestID else { return }
            completion(.success(commits: page.commits, hasMore: page.hasMore))
        }
    }

    /// diff 查询失败的用户文案:统一走 `UserFacingError`(取消/GitServiceError/系统域
    /// 各分支都给中文文案,未本地化的英文 stderr 补中文标识);错误态标题「加载 diff
    /// 失败」由 DiffViewerView 提供,这里只给成因,避免标题与文案重复。
    static func localizedDiffFailureMessage(_ error: Error) -> String {
        UserFacingError.message(for: error)
    }
}

/// 新增仓库的编排:一次 `addRepository` 落盘(含 MR 目标分支与常用链接),返回实时记录。
///
/// 原先内联在 AddRepositorySheetView,View 不直接编排 store 的写入序列(AGENTS.md:
/// 「View 不直接调 git」同一精神)。此前"建档→按 URL 回查 id→updateRepository 回填"
/// 三步写:第二步失败留下"UI 报新增失败、记录已存在、重试撞 duplicateURL"的死角,
/// 回查还依赖裸串相等(传未 trim 值即静默丢分支)。Store 侧 addRepository 单写化
/// 后一并消解(10-10 review P2 修复)。
@MainActor
enum RepositoryAddOrchestrator {
    static func addRepository(
        gitURL: String,
        mrTargetBranches: [String],
        links: [CommonLink] = [],
        store: RepositoryStore
    ) throws -> RepositoryConfig {
        try store.addRepository(gitURL: gitURL, mrTargetBranches: mrTargetBranches, links: links)
    }
}
