import XCTest
@testable import CCSpace

final class BranchSearchTests: XCTestCase {
    func test_substringMatchIsCaseInsensitive() {
        XCTAssertTrue(BranchSearch.matches("feature/login", query: "FEATURE/LO"))
        XCTAssertTrue(BranchSearch.matches("origin/release", query: "lease"))
    }

    func test_subsequenceMatchesWhenQueryCharsScatteredInOrder() {
        // "froin" 不是 "feature/login" 的子串,但字符按序出现(f…r…o…i…n)。
        XCTAssertTrue(BranchSearch.matches("feature/login", query: "froin"))
        XCTAssertTrue(BranchSearch.matches("hotfix/urgent", query: "hfgt"))
    }

    func test_subsequenceRespectsCharacterOrder() {
        // "ifn":i 出现后,其后没有 f,顺序不满足。
        XCTAssertFalse(BranchSearch.matches("feature/login", query: "ifn"))
        XCTAssertFalse(BranchSearch.matches("main", query: "nmi"))
    }

    func test_queryWithMoreCharactersThanBranchNeverMatches() {
        XCTAssertFalse(BranchSearch.matches("main", query: "mainly"))
    }

    func test_noMatchForAbsentCharacters() {
        XCTAssertFalse(BranchSearch.matches("feature/login", query: "zz"))
    }

    func test_emptyQueryMatchesEverything() {
        XCTAssertTrue(BranchSearch.matches("", query: ""))
        XCTAssertTrue(BranchSearch.matches("main", query: ""))
    }
}
