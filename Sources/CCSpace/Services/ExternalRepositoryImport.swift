import Foundation

/// 磁盘上发现、但列表里还没有对应记录的 Git 目录。
struct GitDirectoryCandidate: Sendable, Equatable {
    let workplaceID: UUID
    let path: String
    let folderName: String
}

/// 候选目录加上读到的 origin 远端地址。
struct DiscoveredGitRepository: Sendable, Equatable {
    let workplaceID: UUID
    let path: String
    let folderName: String
    let gitURL: String
}

/// 导入计划里被放弃的目录及原因(交由调用方留痕,纯函数不写日志)。
struct ExternalRepositoryImportSkip: Sendable, Equatable {
    enum Reason: String, Sendable {
        case workplaceMissing
        case pathAlreadyTracked
        case repositoryAlreadyInWorkplace
        case invalidFolderName
        case emptyGitURL
        case repoNameConflict
    }

    let reason: Reason
    let path: String
}

struct ExternalRepositoryImportResult: Sendable {
    let workplaces: [Workplace]
    let repositories: [RepositoryConfig]
    let syncStates: [RepositorySyncState]
    let skips: [ExternalRepositoryImportSkip]
    let importedCount: Int
    let changed: Bool
}

/// 把"用户手动拷进工作区目录的 Git 仓库"变成列表里的正式行(纯函数,便于测试)。
///
/// 背景:工作区的仓库行完全由配置驱动(工作区只存 `selectedRepositoryIDs`,
/// 行是 `RepositorySyncState`),磁盘刷新过去只做"记录对应目录还在不在"的校正,
/// 不枚举目录。于是拷进 `工作区/xxx` 的仓库永远不会出现在列表里。
///
/// 本类型只做两件事:`candidates`(磁盘事实 → 待处理目录)与
/// `importPlan`(待处理目录 + 远端地址 → 三份文档的新状态),都不落盘、不起进程。
enum ExternalRepositoryImport {
    /// 单个工作区每轮最多处理的候选目录数:发现阶段要为每个候选起一次
    /// `git remote get-url`,用户误把整个大目录塞进工作区时不能把刷新拖成长时间占用。
    static let maxCandidatesPerWorkplace = 32

    /// 枚举各工作区目录的**一级子目录**,挑出含 `.git` 且尚未被同步态跟踪的目录。
    ///
    /// 只看一级:仓库的正常形态就是 `工作区/仓库名`,更深层级(如仓库内部的
    /// 子模块、示例工程)不是本工作区管理的仓库,列出来只会制造噪音。
    static func candidates(
        workplaces: [Workplace],
        syncStates: [RepositorySyncState],
        lockedPathKeys: Set<String> = []
    ) -> [GitDirectoryCandidate] {
        let fileManager = FileManager.default
        var discovered: [GitDirectoryCandidate] = []

        for workplace in workplaces {
            let workplacePath = LocalPathSafety.normalizedPath(workplace.path)
            guard workplacePath.isEmpty == false,
                  fileManager.fileExists(atPath: workplacePath) else { continue }
            // 工作区目录本身持锁说明创建/改名/删除正在进行,此刻的目录内容不是稳定事实。
            guard lockedPathKeys.contains(LocalPathSafety.canonicalLockKey(for: workplacePath)) == false else { continue }

            let trackedPaths = Set(
                syncStates
                    .filter { $0.workplaceID == workplace.id }
                    .map { LocalPathSafety.normalizedPath($0.localPath) }
            )
            let childNames = (try? fileManager.contentsOfDirectory(atPath: workplacePath)) ?? []
            var workplaceCandidateCount = 0

            for name in childNames.sorted() {
                guard workplaceCandidateCount < maxCandidatesPerWorkplace else { break }
                // 隐藏目录(`.DS_Store`、`.venv` 等)不是用户眼里的"一个仓库"。
                guard name.hasPrefix(".") == false else { continue }
                // 复用仓库名的拼路径防线:非法组件与越出工作区根都直接跳过。
                guard let childPath = try? WorkplaceStore.repositoryPath(
                    workplacePath: workplacePath,
                    repositoryName: name
                ) else { continue }
                // 符号链接指向工作区外时按"不受管"处理:后续 pull/删除会直接作用在
                // 解析出的真实目录上,不能让它混进列表。
                guard LocalPathSafety.isWithinDirectory(childPath, rootPath: workplacePath) else { continue }
                var isDirectory = ObjCBool(false)
                guard fileManager.fileExists(atPath: childPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                // 目录与文件两种形态都算:`.git` 文件是 worktree/子模块的常见形态。
                guard fileManager.fileExists(
                    atPath: (childPath as NSString).appendingPathComponent(".git")
                ) else { continue }
                guard trackedPaths.contains(LocalPathSafety.normalizedPath(childPath)) == false else { continue }
                // 该目录正在被克隆/删除等操作持锁时跳过,避免与进行中的操作抢同一目录。
                guard lockedPathKeys.contains(LocalPathSafety.canonicalLockKey(for: childPath)) == false else { continue }

                discovered.append(GitDirectoryCandidate(
                    workplaceID: workplace.id,
                    path: childPath,
                    folderName: name
                ))
                workplaceCandidateCount += 1
            }
        }

        return discovered
    }

    /// 生成把候选目录纳入列表的新状态。
    ///
    /// 归属规则(仓库池以 gitURL 为唯一键,磁盘刷新会硬删同 URL 的重复配置):
    /// - 远端地址已存在于仓库池 → 复用该配置,行的 `localPath` 记实际目录
    ///   (目录名可以与配置 `repoName` 不同,读/拉/切分支全部走 `localPath`);
    ///   该工作区里这个仓库已有行时跳过——行 id 是 `工作区-仓库` 组合键,再来一行会撞。
    /// - 远端地址是新仓库 → 以**目录名**为仓库名新建配置,保证 `repoName` 与磁盘目录一致。
    static func importPlan(
        discovered: [DiscoveredGitRepository],
        workplaces: [Workplace],
        syncStates: [RepositorySyncState],
        repositories: [RepositoryConfig],
        now: Date = .now
    ) -> ExternalRepositoryImportResult {
        var updatedWorkplaces = workplaces
        var updatedRepositories = repositories
        var updatedSyncStates = syncStates
        var skips: [ExternalRepositoryImportSkip] = []
        var importedCount = 0

        for item in discovered {
            guard let workplaceIndex = updatedWorkplaces.firstIndex(where: { $0.id == item.workplaceID }) else {
                skips.append(ExternalRepositoryImportSkip(reason: .workplaceMissing, path: item.path))
                continue
            }
            let normalizedItemPath = LocalPathSafety.normalizedPath(item.path)
            guard updatedSyncStates.contains(where: {
                $0.workplaceID == item.workplaceID
                    && LocalPathSafety.normalizedPath($0.localPath) == normalizedItemPath
            }) == false else {
                // 同一批里两个候选指向同一目录(或快照期间已被别的路径建好行)。
                skips.append(ExternalRepositoryImportSkip(reason: .pathAlreadyTracked, path: item.path))
                continue
            }
            let gitURL = item.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard gitURL.isEmpty == false else {
                skips.append(ExternalRepositoryImportSkip(reason: .emptyGitURL, path: item.path))
                continue
            }
            guard (try? LocalPathSafety.validateComponent(item.folderName, fieldName: "仓库名称")) != nil else {
                skips.append(ExternalRepositoryImportSkip(reason: .invalidFolderName, path: item.path))
                continue
            }

            let repositoryID: UUID
            if let matched = updatedRepositories.first(where: { RepositoryStore.gitURLsMatch($0.gitURL, gitURL) }) {
                guard updatedWorkplaces[workplaceIndex].selectedRepositoryIDs.contains(matched.id) == false,
                      updatedSyncStates.contains(where: {
                          $0.workplaceID == item.workplaceID && $0.repositoryID == matched.id
                      }) == false else {
                    skips.append(ExternalRepositoryImportSkip(
                        reason: .repositoryAlreadyInWorkplace,
                        path: item.path
                    ))
                    continue
                }
                repositoryID = matched.id
            } else {
                guard updatedRepositories.contains(where: { $0.repoName == item.folderName }) == false else {
                    // 仓库名在全局池里唯一,同名不同源只能由用户先去重。
                    skips.append(ExternalRepositoryImportSkip(reason: .repoNameConflict, path: item.path))
                    continue
                }
                let repository = RepositoryConfig(
                    id: UUID(),
                    gitURL: gitURL,
                    repoName: item.folderName,
                    createdAt: now,
                    updatedAt: now
                )
                updatedRepositories.append(repository)
                repositoryID = repository.id
            }

            updatedWorkplaces[workplaceIndex].selectedRepositoryIDs.append(repositoryID)
            updatedWorkplaces[workplaceIndex].updatedAt = now
            updatedSyncStates.append(RepositorySyncState(
                workplaceID: item.workplaceID,
                repositoryID: repositoryID,
                status: .idle,
                localPath: normalizedItemPath,
                lastError: nil,
                lastSyncedAt: nil,
                hasLocalDirectory: true
            ))
            importedCount += 1
        }

        return ExternalRepositoryImportResult(
            workplaces: updatedWorkplaces,
            repositories: updatedRepositories,
            syncStates: updatedSyncStates,
            skips: skips,
            importedCount: importedCount,
            changed: importedCount > 0
        )
    }
}
