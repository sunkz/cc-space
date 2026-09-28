import XCTest
@testable import CCSpace

/// FlowLayout 纯布局函数的单元测试:验证 sizeThatFits 与 placeSubviews
/// 共用的行序计算(换行、行高、总高、原点相对性)。
final class FlowLayoutTests: XCTestCase {
    func test_itemsFitInSingleRow_areLaidOutLeftToRight() {
        let sizes = [CGSize(width: 40, height: 20), CGSize(width: 50, height: 14)]
        let result = FlowLayout.layoutPositions(for: sizes, width: 200, spacing: 6)

        XCTAssertEqual(result.positions.map(\.x), [0, 46])
        XCTAssertEqual(result.positions.map(\.y), [0, 0])
        XCTAssertEqual(result.height, 20)
    }

    func test_wrapping_usesSameRowsAsTotalHeight() {
        let sizes = [
            CGSize(width: 60, height: 20),
            CGSize(width: 60, height: 12),
            CGSize(width: 30, height: 18),
        ]
        let result = FlowLayout.layoutPositions(for: sizes, width: 100, spacing: 6)

        // 60 + 6 + 60 > 100 → 第二个换行;30 与第二个同行(60+6+30 < 100+? =96≤100)。
        XCTAssertEqual(result.positions[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(result.positions[1], CGPoint(x: 0, y: 26))
        XCTAssertEqual(result.positions[2], CGPoint(x: 66, y: 26))
        // 总高 = 第一行高 20 + spacing 6 + 第二行最大高 18。
        XCTAssertEqual(result.height, 44)
    }

    func test_emptySubviews_hasZeroHeight() {
        let result = FlowLayout.layoutPositions(for: [], width: 100, spacing: 6)

        XCTAssertTrue(result.positions.isEmpty)
        XCTAssertEqual(result.height, 0)
    }

    func test_positions_areRelativeToOrigin_independentOfBoundsOffset() {
        // 布局函数只接收宽度并返回相对原点点位;placeSubviews 再叠加 bounds.origin。
        // 该测试固定"单一计算源"契约:sizeThatFits(proposal.width) 与
        // placeSubviews(bounds.width) 在相同宽度下得到完全一致的行序。
        let sizes = [
            CGSize(width: 50, height: 10),
            CGSize(width: 50, height: 30),
            CGSize(width: 50, height: 10),
        ]
        let a = FlowLayout.layoutPositions(for: sizes, width: 90, spacing: 4)
        let b = FlowLayout.layoutPositions(for: sizes, width: 90, spacing: 4)

        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.height, b.height)
        // 50 + 4 + 50 = 104 > 90 → 第二、三个各起新行。
        XCTAssertEqual(a.positions.map(\.y), [0, 14, 48])
    }
}
