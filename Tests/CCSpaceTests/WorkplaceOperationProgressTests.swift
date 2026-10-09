import XCTest
@testable import CCSpace

@MainActor
final class WorkplaceOperationProgressTests: XCTestCase {
    func test_trackerEmitsCarryOneStartedAtForTheSameStep() async throws {
        var events: [WorkplaceOperationProgress] = []
        let tracker = WorkplaceOperationProgressTracker(
            step: .cloningRepositories,
            totalCount: 2,
            progressHandler: { progress in
                events.append(progress)
            }
        )

        await tracker.didStart(repositoryName: "api")
        await tracker.didStart(repositoryName: "web")
        await tracker.didFinish(repositoryName: "api")

        XCTAssertEqual(events.count, 3)
        // 计时起点在整步内不变:每次 emit 都刷新会让"已进行时间"回到 0 秒。
        let startedAt = try XCTUnwrap(events.first?.startedAt)
        for event in events {
            XCTAssertEqual(event.startedAt, startedAt)
        }
    }

    func test_progressEqualityIgnoresStartedAt() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let lhs = WorkplaceOperationProgress(
            step: .cloningRepositories,
            completedCount: 1,
            totalCount: 2,
            activeRepositoryNames: ["api"],
            startedAt: base
        )
        let rhs = WorkplaceOperationProgress(
            step: .cloningRepositories,
            completedCount: 1,
            totalCount: 2,
            activeRepositoryNames: ["api"],
            startedAt: base.addingTimeInterval(30)
        )

        // startedAt 不参与相等判定:否则服务层"进度事件序列"断言永远不可能相等。
        XCTAssertEqual(lhs, rhs)

        let differentProgress = WorkplaceOperationProgress(
            step: .cloningRepositories,
            completedCount: 2,
            totalCount: 2,
            activeRepositoryNames: [],
            startedAt: base
        )
        XCTAssertNotEqual(lhs, differentProgress)
    }
}
