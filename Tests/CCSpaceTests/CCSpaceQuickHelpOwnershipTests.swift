import XCTest
@testable import CCSpace

/// 「同一时刻只有一个气泡」的所有权状态机。
///
/// 协调器只把这里的判定落到 NSPopover 上,重入时序(通知前任关闭时,前任会回灌
/// 一次 `release(前任)`,此时不得把刚上位的新人一起清掉)全部在这条链上断言。
final class CCSpaceQuickHelpOwnershipTests: XCTestCase {
    private final class Holder {
        let name: String

        init(_ name: String) {
            self.name = name
        }
    }

    func test_firstClaimRegistersWithoutPredecessor() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        let first = Holder("row")

        XCTAssertNil(ownership.claim(first))
        XCTAssertEqual(ownership.active?.name, "row")
    }

    func test_secondClaimHandsBackThePredecessor() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        let first = Holder("row")
        let second = Holder("button")
        _ = ownership.claim(first)

        let preempted = ownership.claim(second)

        XCTAssertEqual(preempted?.name, "row")
        XCTAssertEqual(ownership.active?.name, "button")
    }

    /// 抢占的核心时序:先登记新人,再通知前任关闭;前任在关闭里回灌的
    /// `release(前任)` 必须落空,否则刚弹出的气泡会立刻失去登记。
    func test_predecessorReleaseAfterPreemptionDoesNotClearSuccessor() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        let first = Holder("row")
        let second = Holder("button")
        _ = ownership.claim(first)
        guard let preempted = ownership.claim(second) else {
            return XCTFail("expected the predecessor to be handed back")
        }

        ownership.release(preempted)

        XCTAssertEqual(ownership.active?.name, "button")
    }

    func test_claimingSameOwnerTwiceDoesNotPreemptItself() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        let first = Holder("row")
        _ = ownership.claim(first)

        XCTAssertNil(ownership.claim(first), "同一挂点重复呈现不该把自己关掉")
        XCTAssertEqual(ownership.active?.name, "row")
    }

    func test_releaseByNonOwnerLeavesRegistrationIntact() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        let first = Holder("row")
        let second = Holder("button")
        _ = ownership.claim(first)
        _ = ownership.claim(second)

        ownership.release(first)

        XCTAssertEqual(ownership.active?.name, "button")
    }

    func test_releaseByCurrentOwnerClearsRegistration() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        let first = Holder("row")
        _ = ownership.claim(first)

        ownership.release(first)

        XCTAssertNil(ownership.active)
        // 清空后下一次 claim 不该再拿到前任。
        XCTAssertNil(ownership.claim(Holder("button")))
    }

    /// 登记必须是弱持有:被 SwiftUI 拆掉的视图不能因为登记而留在内存里
    /// (连同它已离屏的 NSPopover)。
    func test_registrationDoesNotKeepOwnerAlive() {
        var ownership = CCSpaceQuickHelpOwnership<Holder>()
        weak var weakHolder: Holder?
        do {
            let holder = Holder("row")
            weakHolder = holder
            _ = ownership.claim(holder)
            XCTAssertNotNil(ownership.active)
        }

        XCTAssertNil(weakHolder, "前置条件:局部对象出作用域即释放")
        XCTAssertNil(ownership.active)
    }
}
