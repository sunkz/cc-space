import XCTest
@testable import CCSpace

final class ModelPickerPresentationStateTests: XCTestCase {
    private let models = [
        "glm-5.3",
        "glm-5.3-air",
        "glm-5.3-flash",
        "cogview-4",
        "embedding-3",
    ]

    func test_emptySearchReturnsAllModelsInOriginalOrder() {
        let state = ModelPickerPresentationState(models: models, searchText: "")

        XCTAssertEqual(state.filteredModels, models)
    }

    func test_searchFiltersCaseInsensitivelyAndTrimsWhitespace() {
        let state = ModelPickerPresentationState(models: models, searchText: "  GLM-5.3 ")

        XCTAssertEqual(state.filteredModels, ["glm-5.3", "glm-5.3-air", "glm-5.3-flash"])
    }

    func test_searchWithoutMatchReturnsEmpty() {
        let state = ModelPickerPresentationState(models: models, searchText: "gpt")

        XCTAssertTrue(state.filteredModels.isEmpty)
    }

    func test_listHeightGrowsWithRowCountUpToCap() {
        let few = ModelPickerPresentationState(models: Array(models.prefix(3)), searchText: "")
        XCTAssertEqual(
            few.listHeight,
            3 * ModelPickerPresentationState.rowHeight + 8
        )

        let many = ModelPickerPresentationState(
            models: Array(repeating: "m", count: 20).map { "model-\($0)" },
            searchText: ""
        )
        XCTAssertEqual(many.listHeight, ModelPickerPresentationState.maxListHeight)
    }

    func test_footCountTextFollowsFilteredCount() {
        let all = ModelPickerPresentationState(models: models, searchText: "")
        XCTAssertEqual(all.footCountText, "5 个模型")

        let filtered = ModelPickerPresentationState(models: models, searchText: "glm")
        XCTAssertEqual(filtered.footCountText, "3 个模型")
    }
}
