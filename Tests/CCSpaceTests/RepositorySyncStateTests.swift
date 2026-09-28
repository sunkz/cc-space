import XCTest
@testable import CCSpace

final class RepositorySyncStateTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func decodeState(status: String) throws -> RepositorySyncState {
        let json = """
        {
          "workplaceID": "11111111-2222-3333-4444-555555555555",
          "repositoryID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "status": "\(status)",
          "localPath": "/tmp/workplace/repo"
        }
        """
        return try decoder.decode(RepositorySyncState.self, from: Data(json.utf8))
    }

    func test_decodingTransientStatusesResetsToIdle() throws {
        // 崩溃遗留的瞬态状态在重启解码时必须归位,否则仓库会永久卡在"进行中"。
        for transient in ["cloning", "pulling", "removing"] {
            let state = try decodeState(status: transient)
            XCTAssertEqual(state.status, .idle, "持久化的 \(transient) 应重置为 idle")
        }
    }

    func test_decodingTerminalStatusesKeepsValue() throws {
        XCTAssertEqual(try decodeState(status: "idle").status, .idle)
        XCTAssertEqual(try decodeState(status: "success").status, .success)
        XCTAssertEqual(try decodeState(status: "failed").status, .failed)
    }

    func test_decodingResetsHasLocalDirectoryToFalse() throws {
        let state = try decodeState(status: "success")
        XCTAssertFalse(state.hasLocalDirectory)
    }

    /// 未来版本新增的状态字符串不能让整份 sync-states.json 解码失败被重置,
    /// 未知值必须回退为 .idle(与 AppSettings.appearanceMode 的兼容策略一致)。
    func test_decodingUnknownFutureStatusFallsBackToIdle() throws {
        let state = try decodeState(status: "rebasing")
        XCTAssertEqual(state.status, .idle)
    }
}
