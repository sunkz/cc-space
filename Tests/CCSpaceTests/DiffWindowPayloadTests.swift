import XCTest
@testable import CCSpace

final class DiffWindowPayloadTests: XCTestCase {
    private func makePayload(
        source: DiffWindowPayload.Source = .workingDirectory,
        localPath: String = "/tmp/repo"
    ) -> DiffWindowPayload {
        DiffWindowPayload(
            repositoryName: "repo",
            localPath: localPath,
            title: "未提交改动",
            source: source
        )
    }

    func test_equalPayloadsReuseSameWindow() {
        // WindowGroup(for:) 按 value 相等复用窗口:同一仓库同一来源应视为相同窗口。
        XCTAssertEqual(makePayload(), makePayload())
        XCTAssertEqual(
            makePayload(source: .commit(hash: "abc123")),
            makePayload(source: .commit(hash: "abc123"))
        )
        XCTAssertEqual(
            makePayload(source: .compare(base: "main", head: "feat")),
            makePayload(source: .compare(base: "main", head: "feat"))
        )
    }

    func test_differentSourcesOpenDifferentWindows() {
        let base = makePayload()
        XCTAssertNotEqual(base, makePayload(source: .commit(hash: "abc123")))
        XCTAssertNotEqual(base, makePayload(source: .compare(base: "main", head: "feat")))
        XCTAssertNotEqual(
            makePayload(source: .commit(hash: "abc123")),
            makePayload(source: .commit(hash: "def456"))
        )
        // 对比来源的 head 不同(含 detached HEAD 的 nil)也视为不同窗口。
        XCTAssertNotEqual(
            makePayload(source: .compare(base: "main", head: "feat")),
            makePayload(source: .compare(base: "main", head: nil))
        )
        XCTAssertNotEqual(
            makePayload(source: .compare(base: "main", head: "feat")),
            makePayload(source: .compare(base: "develop", head: "feat"))
        )
    }

    func test_differentRepositoriesOpenDifferentWindows() {
        XCTAssertNotEqual(makePayload(), makePayload(localPath: "/tmp/other"))
    }

    func test_codableRoundTripPreservesSource() {
        let cases = [
            DiffWindowPayload.Source.workingDirectory,
            .commit(hash: "abc123"),
            .compare(base: "main", head: "feat"),
            .compare(base: "main", head: nil)
        ]
        for source in cases {
            let payload = makePayload(source: source)
            let data = try! JSONEncoder().encode(payload)
            let decoded = try! JSONDecoder().decode(DiffWindowPayload.self, from: data)
            XCTAssertEqual(decoded, payload)
        }
    }
}
