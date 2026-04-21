import Foundation
import XCTest
@testable import CCSpace

final class CCSpaceLaunchConfigurationTests: XCTestCase {
    func test_parsesScreenshotEnvironmentOverrides() {
        let configuration = CCSpaceLaunchConfiguration(environment: [
            "CCSPACE_APP_SUPPORT_DIR": "/tmp/demo/app-support",
            "CCSPACE_SCREENSHOT_SCENE": "create-workplace",
            "CCSPACE_SCREENSHOT_WORKPLACE_NAME": "analytics-sprint",
            "CCSPACE_SCREENSHOT_CREATE_NAME": "checkout-redesign",
            "CCSPACE_SCREENSHOT_CREATE_BRANCH": "feature/checkout-redesign",
            "CCSPACE_SCREENSHOT_CREATE_SELECTED_REPOSITORIES": "api-gateway, ios-app, docs-portal",
            "CCSPACE_WINDOW_SIZE": "960x640"
        ])

        XCTAssertEqual(configuration.appSupportDirectory?.path, "/tmp/demo/app-support")
        XCTAssertEqual(configuration.screenshotScene, .createWorkplace)
        XCTAssertEqual(configuration.screenshotWorkplaceName, "analytics-sprint")
        XCTAssertEqual(configuration.createWorkplaceName, "checkout-redesign")
        XCTAssertEqual(configuration.createWorkplaceBranch, "feature/checkout-redesign")
        XCTAssertEqual(
            configuration.createSelectedRepositoryNames,
            ["api-gateway", "ios-app", "docs-portal"]
        )
        XCTAssertEqual(configuration.windowSize.width, 960)
        XCTAssertEqual(configuration.windowSize.height, 640)
    }

    func test_usesScreenshotDefaultWindowSizeWhenOnlySceneIsProvided() {
        let configuration = CCSpaceLaunchConfiguration(environment: [
            "CCSPACE_SCREENSHOT_SCENE": "settings-overview"
        ])

        XCTAssertEqual(configuration.screenshotScene, .settingsOverview)
        XCTAssertEqual(configuration.windowSize.width, 960)
        XCTAssertEqual(configuration.windowSize.height, 640)
    }

    func test_createWorkplaceSeedResolvesRepositoryIDsByName() {
        let apiGatewayID = UUID()
        let iosAppID = UUID()
        let repositories = [
            RepositoryConfig(
                id: apiGatewayID,
                gitURL: "git@cc:api-gateway.git",
                repoName: "api-gateway",
                defaultBranch: "main",
                mrTargetBranches: ["main"],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            RepositoryConfig(
                id: iosAppID,
                gitURL: "git@cc:ios-app.git",
                repoName: "ios-app",
                defaultBranch: "main",
                mrTargetBranches: ["main"],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        ]
        let configuration = CCSpaceLaunchConfiguration(environment: [
            "CCSPACE_SCREENSHOT_SCENE": "create-workplace",
            "CCSPACE_SCREENSHOT_CREATE_NAME": "checkout-redesign",
            "CCSPACE_SCREENSHOT_CREATE_BRANCH": "feature/checkout-redesign",
            "CCSPACE_SCREENSHOT_CREATE_SELECTED_REPOSITORIES": "api-gateway, ios-app"
        ])

        let seed = configuration.createWorkplaceSeed(repositories: repositories)

        XCTAssertEqual(seed.name, "checkout-redesign")
        XCTAssertEqual(seed.branch, "feature/checkout-redesign")
        XCTAssertEqual(seed.selectedRepositoryIDs, Set([apiGatewayID, iosAppID]))
    }
}
