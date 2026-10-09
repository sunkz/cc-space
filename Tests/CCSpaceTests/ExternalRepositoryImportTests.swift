import XCTest
@testable import CCSpace

/// 磁盘发现导入的纯函数测试。
///
/// `candidates` 用真实临时目录(判定依赖文件系统形态:.git 目录/.git 文件/符号链接),
/// `importPlan` 只吃内存对象,不需要磁盘。
final class ExternalRepositoryImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWorkplace(name: String, path: String, selected: [UUID] = []) -> Workplace {
        Workplace(
            id: UUID(),
            name: name,
            path: path,
            selectedRepositoryIDs: selected,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeRepository(gitURL: String, repoName: String) -> RepositoryConfig {
        RepositoryConfig(
            id: UUID(),
            gitURL: gitURL,
            repoName: repoName,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 在工作区目录下建一个"看起来像个仓库"的子目录。
    @discardableResult
    private func makeGitDirectory(
        named name: String,
        in workplacePath: String,
        asFile: Bool = false
    ) throws -> String {
        let fm = FileManager.default
        let childPath = URL(fileURLWithPath: workplacePath).appendingPathComponent(name).path
        let gitMarker = URL(fileURLWithPath: childPath).appendingPathComponent(".git").path
        if asFile {
            try fm.createDirectory(atPath: childPath, withIntermediateDirectories: true)
            try Data("gitdir: /elsewhere/.git".utf8).write(to: URL(fileURLWithPath: gitMarker))
        } else {
            try fm.createDirectory(
                atPath: URL(fileURLWithPath: gitMarker).path,
                withIntermediateDirectories: true
            )
        }
        return childPath
    }

    func test_candidatesOnlyIncludesUntrackedGitDirectories() throws {
        let root = makeTestRootURL()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let workplace = makeWorkplace(name: "ws", path: root.appendingPathComponent("ws").path)
        try fm.createDirectory(atPath: workplace.path, withIntermediateDirectories: true)

        let trackedRepo = try makeGitDirectory(named: "tracked-repo", in: workplace.path)
        _ = try makeGitDirectory(named: "worktree-repo", in: workplace.path, asFile: true)
        _ = try makeGitDirectory(named: "new-repo", in: workplace.path)
        // 普通目录(无 .git)与隐藏目录都不算仓库
        try fm.createDirectory(
            atPath: URL(fileURLWithPath: workplace.path).appendingPathComponent("notes").path,
            withIntermediateDirectories: true
        )
        _ = try makeGitDirectory(named: ".hidden-repo", in: workplace.path)

        let syncState = RepositorySyncState(
            workplaceID: workplace.id,
            repositoryID: UUID(),
            status: .success,
            localPath: trackedRepo,
            hasLocalDirectory: true
        )

        let found = ExternalRepositoryImport.candidates(
            workplaces: [workplace],
            syncStates: [syncState]
        )
        XCTAssertEqual(found.map(\.folderName), ["new-repo", "worktree-repo"])
        XCTAssertEqual(
            Set(found.map(\.path)),
            Set([
                URL(fileURLWithPath: workplace.path).appendingPathComponent("new-repo").path,
                URL(fileURLWithPath: workplace.path).appendingPathComponent("worktree-repo").path,
            ])
        )
    }

    func test_candidatesSkipLockedWorkplaceAndDirectory() throws {
        let root = makeTestRootURL()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let workplace = makeWorkplace(name: "ws", path: root.appendingPathComponent("ws").path)
        let lockedChild = try makeGitDirectory(named: "locked-repo", in: workplace.path)
        _ = try makeGitDirectory(named: "free-repo", in: workplace.path)

        // 子目录持锁(正在克隆/删除)→ 该候选不列出,同级的其它候选不受影响
        let lockedOnly = ExternalRepositoryImport.candidates(
            workplaces: [workplace],
            syncStates: [],
            lockedPathKeys: [LocalPathSafety.canonicalLockKey(for: lockedChild)]
        )
        XCTAssertEqual(lockedOnly.map(\.folderName), ["free-repo"])

        // 工作区目录持锁(创建/改名进行中)→ 整个工作区跳过
        let workplaceLocked = ExternalRepositoryImport.candidates(
            workplaces: [workplace],
            syncStates: [],
            lockedPathKeys: [LocalPathSafety.canonicalLockKey(for: workplace.path)]
        )
        XCTAssertTrue(workplaceLocked.isEmpty)
    }

    func test_candidatesCapPerWorkplace() throws {
        let root = makeTestRootURL()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let workplace = makeWorkplace(name: "ws", path: root.appendingPathComponent("ws").path)
        try fm.createDirectory(atPath: workplace.path, withIntermediateDirectories: true)
        for index in 0..<(ExternalRepositoryImport.maxCandidatesPerWorkplace + 2) {
            _ = try makeGitDirectory(named: "repo-\(index)", in: workplace.path)
        }

        let found = ExternalRepositoryImport.candidates(workplaces: [workplace], syncStates: [])
        XCTAssertEqual(found.count, ExternalRepositoryImport.maxCandidatesPerWorkplace)
    }

    func test_importPlanCreatesRepositoryFromFolderName() {
        let workplace = makeWorkplace(name: "ws", path: "/tmp/ws")
        let discovered = DiscoveredGitRepository(
            workplaceID: workplace.id,
            path: "/tmp/ws/copied-repo",
            folderName: "copied-repo",
            gitURL: "git@github.com:org/copied.git"
        )

        let result = ExternalRepositoryImport.importPlan(
            discovered: [discovered],
            workplaces: [workplace],
            syncStates: [],
            repositories: [],
            now: now
        )

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skips, [])
        // 仓库名取磁盘目录名,保证 repoName 与实际目录一致
        XCTAssertEqual(result.repositories.count, 1)
        XCTAssertEqual(result.repositories.first?.gitURL, "git@github.com:org/copied.git")
        XCTAssertEqual(result.repositories.first?.repoName, "copied-repo")
        let state = try? XCTUnwrap(result.syncStates.first)
        XCTAssertEqual(state?.workplaceID, workplace.id)
        XCTAssertEqual(state?.localPath, "/tmp/ws/copied-repo")
        XCTAssertEqual(state?.status, .idle)
        XCTAssertEqual(state?.hasLocalDirectory, true)
        XCTAssertEqual(result.workplaces.first?.selectedRepositoryIDs, result.repositories.map(\.id))
    }

    func test_importPlanReusesExistingRepositoryMatchedByURL() {
        // 远端地址已在仓库池里(归一化口径同 RepositoryStore:大小写、.git、尾斜杠)
        let existing = makeRepository(gitURL: "https://github.com/org/blog.git", repoName: "blog")
        let workplace = makeWorkplace(name: "ws", path: "/tmp/ws")
        let discovered = DiscoveredGitRepository(
            workplaceID: workplace.id,
            path: "/tmp/ws/blog-copy",
            folderName: "blog-copy",
            gitURL: "https://github.com/org/blog"
        )

        let result = ExternalRepositoryImport.importPlan(
            discovered: [discovered],
            workplaces: [workplace],
            syncStates: [],
            repositories: [existing],
            now: now
        )

        XCTAssertEqual(result.importedCount, 1)
        // 不新建配置:仓库池仍以 URL 为唯一键,重复 URL 会被刷新去重硬删
        XCTAssertEqual(result.repositories.count, 1)
        XCTAssertEqual(result.syncStates.first?.repositoryID, existing.id)
        XCTAssertEqual(result.syncStates.first?.localPath, "/tmp/ws/blog-copy")
    }

    func test_importPlanSkipsRemoteAlreadyPresentInWorkplace() {
        let existing = makeRepository(gitURL: "git@github.com:org/blog.git", repoName: "blog")
        let workplace = makeWorkplace(name: "ws", path: "/tmp/ws", selected: [existing.id])
        let discovered = DiscoveredGitRepository(
            workplaceID: workplace.id,
            path: "/tmp/ws/blog-fork-dir",
            folderName: "blog-fork-dir",
            gitURL: "git@github.com:org/blog.git"
        )

        let result = ExternalRepositoryImport.importPlan(
            discovered: [discovered],
            workplaces: [workplace],
            syncStates: [RepositorySyncState(
                workplaceID: workplace.id,
                repositoryID: existing.id,
                status: .success,
                localPath: "/tmp/ws/blog",
                hasLocalDirectory: true
            )],
            repositories: [existing],
            now: now
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.skips.map(\.reason), [.repositoryAlreadyInWorkplace])
    }

    func test_importPlanSkipsFolderNameCollidingWithOtherRepository() {
        let other = makeRepository(gitURL: "git@github.com:org/blog.git", repoName: "copied-repo")
        let workplace = makeWorkplace(name: "ws", path: "/tmp/ws")
        let discovered = DiscoveredGitRepository(
            workplaceID: workplace.id,
            path: "/tmp/ws/copied-repo",
            folderName: "copied-repo",
            gitURL: "git@github.com:other/copied-repo.git"
        )

        let result = ExternalRepositoryImport.importPlan(
            discovered: [discovered],
            workplaces: [workplace],
            syncStates: [],
            repositories: [other],
            now: now
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.skips.map(\.reason), [.repoNameConflict])
    }

    func test_importPlanSkipsMissingWorkplaceEmptyURLAndDuplicatePath() {
        let workplace = makeWorkplace(name: "ws", path: "/tmp/ws")
        let item = DiscoveredGitRepository(
            workplaceID: workplace.id,
            path: "/tmp/ws/repo",
            folderName: "repo",
            gitURL: "git@github.com:org/repo.git"
        )

        let missingWorkplace = ExternalRepositoryImport.importPlan(
            discovered: [DiscoveredGitRepository(
                workplaceID: UUID(),
                path: "/tmp/gone/repo",
                folderName: "repo",
                gitURL: "git@github.com:org/repo.git"
            )],
            workplaces: [workplace],
            syncStates: [],
            repositories: [],
            now: now
        )
        XCTAssertEqual(missingWorkplace.skips.map(\.reason), [.workplaceMissing])
        XCTAssertFalse(missingWorkplace.changed)

        let emptyURL = ExternalRepositoryImport.importPlan(
            discovered: [DiscoveredGitRepository(
                workplaceID: workplace.id,
                path: "/tmp/ws/local-only",
                folderName: "local-only",
                gitURL: "   "
            )],
            workplaces: [workplace],
            syncStates: [],
            repositories: [],
            now: now
        )
        XCTAssertEqual(emptyURL.skips.map(\.reason), [.emptyGitURL])
        XCTAssertFalse(emptyURL.changed)

        // 同一批两个候选指向同一目录:第二条按已跟踪跳过,不落双行
        let duplicatedPath = ExternalRepositoryImport.importPlan(
            discovered: [item, item],
            workplaces: [workplace],
            syncStates: [],
            repositories: [],
            now: now
        )
        XCTAssertEqual(duplicatedPath.importedCount, 1)
        XCTAssertEqual(duplicatedPath.skips.map(\.reason), [.pathAlreadyTracked])
        XCTAssertEqual(duplicatedPath.syncStates.count, 1)
    }
}
