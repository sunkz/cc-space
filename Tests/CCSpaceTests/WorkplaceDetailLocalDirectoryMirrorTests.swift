import XCTest
@testable import CCSpace

/// 长驻轮询/分支加载读的是 @State 镜像而非视图拷贝上的 syncStates,
/// 镜像内容由 WorkplaceDetailLocalDirectoryMirror 从当前 syncStates 求值。
final class WorkplaceDetailLocalDirectoryMirrorTests: XCTestCase {
    func test_emptySyncStatesYieldsEmptyMirror() {
        let mirror = WorkplaceDetailLocalDirectoryMirror(syncStates: [])

        XCTAssertFalse(mirror.hasAnyLocalDirectory)
        XCTAssertTrue(mirror.localDirectoryStates.isEmpty)
    }

    func test_mirrorKeepsOnlyLocalDirectoryStates() {
        let local = makeSyncState(status: .success, hasLocalDirectory: true)
        let remoteOnly = makeSyncState(status: .idle, hasLocalDirectory: false)

        let mirror = WorkplaceDetailLocalDirectoryMirror(syncStates: [local, remoteOnly])

        XCTAssertTrue(mirror.hasAnyLocalDirectory)
        XCTAssertEqual(mirror.localDirectoryStates.map(\.id), [local.id])
    }

    func test_allStatesMissingLocalDirectoryDisablesHeartbeat() {
        let states = [
            makeSyncState(status: .idle, hasLocalDirectory: false),
            makeSyncState(status: .failed, hasLocalDirectory: false)
        ]

        let mirror = WorkplaceDetailLocalDirectoryMirror(syncStates: states)

        // 目录缺失/未克隆时轮询与分支快照整体跳过,镜像必须如实反映,
        // 否则 5 秒心跳会在无本地仓库的工作区上空转。
        XCTAssertFalse(mirror.hasAnyLocalDirectory)
        XCTAssertTrue(mirror.localDirectoryStates.isEmpty)
    }

    func test_mirrorIsValueEqualWhenSyncStatesUnchanged() {
        let states = [makeSyncState(status: .success, hasLocalDirectory: true)]

        XCTAssertEqual(
            WorkplaceDetailLocalDirectoryMirror(syncStates: states),
            WorkplaceDetailLocalDirectoryMirror(syncStates: states)
        )
    }

    private func makeSyncState(
        status: SyncStatus,
        hasLocalDirectory: Bool
    ) -> RepositorySyncState {
        RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: status,
            localPath: hasLocalDirectory ? "/tmp/blog" : "",
            lastError: nil,
            lastSyncedAt: nil,
            hasLocalDirectory: hasLocalDirectory
        )
    }
}
