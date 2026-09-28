import XCTest
@testable import CCSpace

final class AICommitResponseParserTests: XCTestCase {
    private func makeResponseData(content: String) -> Data {
        let payload = [
            "choices": [
                ["message": ["content": content]]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func test_parsePlainContent() throws {
        let message = try AICommitResponseParser.parseCommitMessage(
            from: makeResponseData(content: "feat: 添加 AI 提交信息")
        )

        XCTAssertEqual(message, "feat: 添加 AI 提交信息")
    }

    func test_parseStripsMarkdownFenceWithLanguageTag() throws {
        let message = try AICommitResponseParser.parseCommitMessage(
            from: makeResponseData(content: "```text\nfeat: 添加功能\n```")
        )

        XCTAssertEqual(message, "feat: 添加功能")
    }

    func test_parseStripsSurroundingQuotes() throws {
        let message = try AICommitResponseParser.parseCommitMessage(
            from: makeResponseData(content: "\"feat: 添加功能\"")
        )

        XCTAssertEqual(message, "feat: 添加功能")
    }

    func test_parseTakesFirstNonEmptyLine() throws {
        let message = try AICommitResponseParser.parseCommitMessage(
            from: makeResponseData(content: "feat: 添加功能\n\n这是补充说明,提交栏只保留主题行。")
        )

        XCTAssertEqual(message, "feat: 添加功能")
    }

    func test_parseEmptyContentThrowsEmptyResponse() {
        XCTAssertThrowsError(
            try AICommitResponseParser.parseCommitMessage(from: makeResponseData(content: "  "))
        ) { error in
            guard case AICommitMessageError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }

    func test_parseInvalidJSONThrowsChineseInvalidResponseFormat() {
        // 网关 200 + HTML/非 JSON 响应:原始英文 DecodingError 不得直出 UI。
        XCTAssertThrowsError(
            try AICommitResponseParser.parseCommitMessage(from: Data("not json".utf8))
        ) { error in
            guard case AICommitMessageError.invalidResponseFormat = error else {
                return XCTFail("Expected invalidResponseFormat, got \(error)")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("无法解析"),
                "实际文案：\(error.localizedDescription)"
            )
        }
        XCTAssertThrowsError(
            try AICommitResponseParser.parseCommitMessage(
                from: Data("<html><body>502 Bad Gateway</body></html>".utf8)
            )
        ) { error in
            guard case AICommitMessageError.invalidResponseFormat = error else {
                return XCTFail("Expected invalidResponseFormat, got \(error)")
            }
        }
    }

    func test_parseJSONWithIncompatibleShapeThrowsInvalidResponseFormat() {
        // 合法 JSON 但字段类型与 OpenAI 兼容结构不符(如 choices 为字符串)。
        XCTAssertThrowsError(
            try AICommitResponseParser.parseCommitMessage(from: Data(#"{"choices":"oops"}"#.utf8))
        ) { error in
            guard case AICommitMessageError.invalidResponseFormat = error else {
                return XCTFail("Expected invalidResponseFormat, got \(error)")
            }
        }
    }

    func test_sanitizeHandlesCurlyQuotesAndLeadingBlankLines() {
        let sanitized = AICommitResponseParser.sanitize("\n\n“feat: 添加功能”\n")

        XCTAssertEqual(sanitized, "feat: 添加功能")
    }
}
