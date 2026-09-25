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

    func test_parseInvalidJSONThrows() {
        XCTAssertThrowsError(
            try AICommitResponseParser.parseCommitMessage(from: Data("not json".utf8))
        )
    }

    func test_sanitizeHandlesCurlyQuotesAndLeadingBlankLines() {
        let sanitized = AICommitResponseParser.sanitize("\n\n“feat: 添加功能”\n")

        XCTAssertEqual(sanitized, "feat: 添加功能")
    }
}
