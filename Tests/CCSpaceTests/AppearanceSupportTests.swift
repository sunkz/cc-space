import XCTest
import AppKit
@testable import CCSpace

final class AppearanceSupportTests: XCTestCase {
    func test_modeCycleOrderIsLightDarkSystem() {
        XCTAssertEqual(AppSettings.AppearanceMode.light.nextInCycle, .dark)
        XCTAssertEqual(AppSettings.AppearanceMode.dark.nextInCycle, .system)
        XCTAssertEqual(AppSettings.AppearanceMode.system.nextInCycle, .light)
        XCTAssertEqual(
            AppSettings.AppearanceMode.cycleOrder,
            [.light, .dark, .system]
        )
    }

    func test_modeToolbarMetadata() {
        XCTAssertEqual(AppSettings.AppearanceMode.light.toolbarSystemImage, "sun.max.fill")
        XCTAssertEqual(AppSettings.AppearanceMode.dark.toolbarSystemImage, "moon.fill")
        XCTAssertEqual(AppSettings.AppearanceMode.system.toolbarSystemImage, "circle.lefthalf.filled")

        XCTAssertEqual(
            AppSettings.AppearanceMode.dark.toolbarButtonTitle,
            "外观:深色,点击切换到跟随系统"
        )
        XCTAssertEqual(
            AppSettings.AppearanceMode.system.toolbarButtonTitle,
            "外观:跟随系统,点击切换到浅色"
        )
    }

    func test_nsAppearanceNameMapping() {
        XCTAssertNil(AppearanceModeApplier.nsAppearanceName(for: .system))
        XCTAssertEqual(AppearanceModeApplier.nsAppearanceName(for: .light), .aqua)
        XCTAssertEqual(AppearanceModeApplier.nsAppearanceName(for: .dark), .darkAqua)
    }

    func test_isOverrideOutOfSyncDetectsMissingAndMismatchedOverride() {
        // system 模式期望无覆盖(nil)。
        XCTAssertFalse(AppearanceModeApplier.isOverrideOutOfSync(nil, with: .system))
        XCTAssertTrue(AppearanceModeApplier.isOverrideOutOfSync(.aqua, with: .system))

        // 显式模式:覆盖一致为同步,缺失(nil,被外部重置)或相反均为不同步。
        XCTAssertFalse(AppearanceModeApplier.isOverrideOutOfSync(.aqua, with: .light))
        XCTAssertFalse(AppearanceModeApplier.isOverrideOutOfSync(.darkAqua, with: .dark))
        XCTAssertTrue(AppearanceModeApplier.isOverrideOutOfSync(nil, with: .light))
        XCTAssertTrue(AppearanceModeApplier.isOverrideOutOfSync(nil, with: .dark))
        XCTAssertTrue(AppearanceModeApplier.isOverrideOutOfSync(.darkAqua, with: .light))
        XCTAssertTrue(AppearanceModeApplier.isOverrideOutOfSync(.aqua, with: .dark))
    }
}
