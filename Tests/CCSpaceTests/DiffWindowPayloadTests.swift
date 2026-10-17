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
    }

    func test_differentSourcesOpenDifferentWindows() {
        let base = makePayload()
        XCTAssertNotEqual(base, makePayload(source: .commit(hash: "abc123")))
        XCTAssertNotEqual(
            makePayload(source: .commit(hash: "abc123")),
            makePayload(source: .commit(hash: "def456"))
        )
    }

    func test_differentRepositoriesOpenDifferentWindows() {
        XCTAssertNotEqual(makePayload(), makePayload(localPath: "/tmp/other"))
    }

    func test_codableRoundTripPreservesSource() {
        let cases = [
            DiffWindowPayload.Source.workingDirectory,
            .commit(hash: "abc123")
        ]
        for source in cases {
            let payload = makePayload(source: source)
            let data = try! JSONEncoder().encode(payload)
            let decoded = try! JSONDecoder().decode(DiffWindowPayload.self, from: data)
            XCTAssertEqual(decoded, payload)
        }
    }
}
