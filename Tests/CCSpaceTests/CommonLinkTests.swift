import XCTest
@testable import CCSpace

@MainActor
final class CommonLinkTests: XCTestCase {

    // MARK: - CommonLinksInput 纯逻辑

    func test_rowError_semantics() {
        // 全空行合法:提交时静默丢弃,不报错。
        XCTAssertNil(CommonLinksInput.rowError(title: "", url: ""))
        XCTAssertNil(CommonLinksInput.rowError(title: "  ", url: "  "))
        XCTAssertEqual(CommonLinksInput.rowError(title: "", url: "https://a.com"), "请填写标题")
        XCTAssertEqual(CommonLinksInput.rowError(title: "看板", url: ""), "请填写链接地址")
        XCTAssertEqual(
            CommonLinksInput.rowError(title: "看板", url: "ftp://a.com"),
            "链接需以 http:// 或 https:// 开头"
        )
        XCTAssertNil(CommonLinksInput.rowError(title: "看板", url: "https://a.com/board"))
    }

    func test_isValidURL_acceptsOnlyHttpsWithHost() {
        XCTAssertTrue(CommonLinksInput.isValidURL("https://example.com/a"))
        XCTAssertTrue(CommonLinksInput.isValidURL("http://example.com"))
        XCTAssertFalse(CommonLinksInput.isValidURL("git@github.com:org/api.git"))
        XCTAssertFalse(CommonLinksInput.isValidURL("javascript:alert(1)"))
        // 有 scheme 无 host 不算合法。
        XCTAssertFalse(CommonLinksInput.isValidURL("https://"))
    }

    func test_normalizedForSave_trimsAndDropsBlankRowsPreservingOrder() {
        let rows = [
            CommonLink(title: " Jenkins ", url: " https://j.example.com "),
            CommonLink(title: "", url: ""),
            CommonLink(title: "看板", url: "https://b.example.com"),
        ]
        let saved = CommonLinksInput.normalizedForSave(rows: rows)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved[0].title, "Jenkins")
        XCTAssertEqual(saved[0].url, "https://j.example.com")
        // 保留原 id:编辑期落盘后行身份稳定。
        XCTAssertEqual(saved[1].id, rows[2].id)
    }

    func test_hasBlockingError() {
        XCTAssertFalse(CommonLinksInput.hasBlockingError(rows: [CommonLink(title: "", url: "")]))
        XCTAssertTrue(
            CommonLinksInput.hasBlockingError(rows: [CommonLink(title: "x", url: "not-a-url")])
        )
    }

    // MARK: - Codable 兼容(老数据无 links 字段)

    func test_repositoryConfig_legacyJSON_decodesEmptyLinks() throws {
        let legacy = """
        {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","gitURL":"git@github.com:o/r.git",\
        "repoName":"r","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoded = try JSONFileStore.makeDecoder().decode(
            RepositoryConfig.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.links, [])
    }

    func test_repositoryConfig_linksRoundTrip() throws {
        // iso8601 编码只到秒:.now 的亚秒会在往返中丢失,断言必须用整秒日期。
        let stamp = Date(timeIntervalSince1970: 1_767_225_600)
        let config = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:o/r.git",
            repoName: "r",
            links: [CommonLink(title: "Jenkins", url: "https://j.example.com")],
            createdAt: stamp,
            updatedAt: stamp
        )
        let data = try JSONFileStore.makeEncoder().encode(config)
        let decoded = try JSONFileStore.makeDecoder().decode(RepositoryConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func test_workplace_legacyJSON_decodesEmptyLinks() throws {
        let legacy = """
        {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"w","path":"/tmp/w",\
        "selectedRepositoryIDs":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoded = try JSONFileStore.makeDecoder().decode(Workplace.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.links, [])
    }

    func test_workplace_linksRoundTrip() throws {
        let stamp = Date(timeIntervalSince1970: 1_767_225_600)
        let workplace = Workplace(
            id: UUID(),
            name: "w",
            path: "/tmp/w",
            selectedRepositoryIDs: [],
            links: [
                CommonLink(title: "需求", url: "https://doc.example.com/req"),
                CommonLink(title: "环境", url: "http://env.example.com"),
            ],
            createdAt: stamp,
            updatedAt: stamp
        )
        let data = try JSONFileStore.makeEncoder().encode(workplace)
        let decoded = try JSONFileStore.makeDecoder().decode(Workplace.self, from: data)
        XCTAssertEqual(decoded, workplace)
    }

    func test_backupEntry_legacyJSON_decodesEmptyLinks() throws {
        let legacy = """
        {"gitURL":"git@github.com:o/r.git","mrTargetBranches":["main"]}
        """
        let decoded = try JSONFileStore.makeDecoder().decode(
            RepositoryBackupEntry.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.links, [])
    }

    // MARK: - RepositoryStore 落盘行为

    func test_addRepository_persistsLinks() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)
        let links = [CommonLink(title: "Jenkins", url: "https://j.example.com")]

        try store.addRepository(gitURL: "git@github.com:org/api.git", links: links)

        let reloaded = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.repositories.first?.links, links)
    }

    func test_updateLinks_replacesAndPersists() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)
        try store.addRepository(
            gitURL: "git@github.com:org/api.git",
            links: [CommonLink(title: "旧", url: "https://old.example.com")]
        )
        let id = store.repositories[0].id

        try store.updateLinks(id: id, links: [CommonLink(title: "新", url: "https://new.example.com")])

        let reloaded = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.repositories.first?.links.count, 1)
        XCTAssertEqual(reloaded.repositories.first?.links.first?.title, "新")
    }

    /// 导入合并:本地已有链接的行不得被旧备份复活已删链接;本地为空才回填。
    func test_importBackup_linksOnlyBackfillWhenLocalEmpty() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)
        try store.addRepository(
            gitURL: "git@github.com:org/api.git",
            links: [CommonLink(title: "在", url: "https://keep.example.com")]
        )
        try store.updateLinks(id: store.repositories[0].id, links: [])

        let entries = [
            RepositoryBackupEntry(
                gitURL: "git@github.com:org/api.git",
                links: [CommonLink(title: "备份", url: "https://backup.example.com")]
            )
        ]
        let result = try store.importBackup(entries: entries)
        XCTAssertEqual(result.mergedCount, 1)
        XCTAssertEqual(store.repositories[0].links.first?.title, "备份")

        // 本地已有链接:再导同一备份不合并(不复活、不重复)。
        let second = try store.importBackup(entries: entries)
        XCTAssertEqual(second.mergedCount, 0)
        XCTAssertEqual(store.repositories[0].links.count, 1)
    }

    // MARK: - 编辑弹窗提交闸

    func test_repositoryEditState_linksOnlyChangeEnablesSubmit() {
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        let changed = RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: repository.id,
            editingGitURL: repository.gitURL,
            editingLinks: [CommonLink(title: "看板", url: "https://b.example.com")]
        )
        XCTAssertTrue(changed.canSubmit)

        // 只加空行不算改动,也不阻塞。
        let blankOnly = RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: repository.id,
            editingGitURL: repository.gitURL,
            editingLinks: [CommonLink(title: "", url: "")]
        )
        XCTAssertFalse(blankOnly.canSubmit)

        // 非法链接行阻塞保存。
        let invalid = RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: repository.id,
            editingGitURL: repository.gitURL,
            editingLinks: [CommonLink(title: "看板", url: "ftp://bad")]
        )
        XCTAssertFalse(invalid.canSubmit)
    }

    func test_workplaceEditState_linksChangeEnablesSubmitAndSummarizes() {
        // 选中集合必须用同一 UUID:两个不同 UUID 会被算成"新增+移除仓库",
        // 摘要文案就混入无关变更段了。
        let repositoryID = UUID()
        let state = WorkplaceEditPresentationState(
            originalName: "w",
            name: "w",
            originalBranch: nil,
            branch: "",
            originalSelectedRepositoryIDs: [repositoryID],
            selectedRepositoryIDs: [repositoryID],
            originalLinks: [],
            editingLinks: [CommonLink(title: "文档", url: "https://doc.example.com")],
            isSaving: false
        )
        XCTAssertTrue(state.canSubmit)
        XCTAssertEqual(
            state.changeSummaryFeedback?.message,
            "将更新常用链接"
        )
    }

    // MARK: - 打开链接动作

    func test_runOpenCommonLink_opensURLWithoutBranchRefresh() async throws {
        let coordinator = WorkplaceDetailActionCoordinator()
        let url = try XCTUnwrap(URL(string: "https://jenkins.example.com/job/api"))
        var openedURLs: [URL] = []

        RootSplitWorkplaceActions.runOpenCommonLink(
            coordinator: coordinator,
            link: CommonLink(title: "Jenkins", url: url.absoluteString),
            openInBrowser: { openedURLs.append($0) }
        )

        await waitUntil(coordinator.isRunningAction == false)

        XCTAssertEqual(openedURLs, [url])
        XCTAssertNil(coordinator.feedback)
        XCTAssertEqual(coordinator.branchRefreshSeed, 0)
    }

    func test_runOpenCommonLink_reportsInvalidURL() async throws {
        let coordinator = WorkplaceDetailActionCoordinator()

        RootSplitWorkplaceActions.runOpenCommonLink(
            coordinator: coordinator,
            // 空串必失败:带空格的串会被 lenient URL 解析器 percent-encode 成合法 URL,
            // 测不出 guard(录入侧校验已挡空格串,这里只兜构造失败)。
            link: CommonLink(title: "坏", url: ""),
            openInBrowser: { _ in }
        )

        await waitUntil(coordinator.isRunningAction == false)

        guard case .some(let feedback) = coordinator.feedback else {
            return XCTFail("非法链接应弹错误反馈")
        }
        XCTAssertEqual(feedback.style, .error)
        XCTAssertTrue(feedback.message.contains("链接地址无法解析"))
    }

    /// 协调器动作为 fire-and-forget Task,断言前等其收尾(同 RootSplitViewSupportTests 辅助)。
    private func waitUntil(
        _ condition: @autoclosure @escaping () -> Bool,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().timeIntervalSince1970 + Double(timeoutNanoseconds) / 1_000_000_000

        while condition() == false {
            guard Date().timeIntervalSince1970 < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
