import XCTest
@testable import CCSpace

final class AIModelListParserTests: XCTestCase {
    func test_parseOpenAIStyleDataEntries() throws {
        let payload = #"{"object":"list","data":[{"id":"glm-5.3"},{"id":"glm-5.3-flash"}]}"#

        let models = try AIModelListParser.parseModelIDs(from: Data(payload.utf8))

        XCTAssertEqual(models, ["glm-5.3", "glm-5.3-flash"])
    }

    func test_parseCodingStyleModelEntries() throws {
        let payload = #"{"models":[{"slug":"glm-5.3"},{"id":"glm-5-turbo"}]}"#

        let models = try AIModelListParser.parseModelIDs(from: Data(payload.utf8))

        XCTAssertEqual(models, ["glm-5.3", "glm-5-turbo"])
    }

    func test_parseFiltersEmptyIDsAndDeduplicatesKeepingOrder() throws {
        let payload = #"{"data":[{"id":"a"},{"id":""},{"id":"b"},{"id":"a"},{"slug":null}]}"#

        let models = try AIModelListParser.parseModelIDs(from: Data(payload.utf8))

        XCTAssertEqual(models, ["a", "b"])
    }

    func test_parseInvalidShapeThrowsInvalidModelList() {
        XCTAssertThrowsError(
            try AIModelListParser.parseModelIDs(from: Data("not json".utf8))
        ) { error in
            guard case AICommitMessageError.invalidModelList = error else {
                return XCTFail("Expected invalidModelList, got \(error)")
            }
        }
    }
}
