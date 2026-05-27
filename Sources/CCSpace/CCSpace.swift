import SwiftUI

@main
struct CCSpace: App {
    private let launchConfiguration = CCSpaceLaunchConfiguration()

    var body: some Scene {
        Window("CCSpace", id: "main") {
            RootSplitView(launchConfiguration: launchConfiguration)
        }
        .defaultSize(
            width: launchConfiguration.windowSize.width,
            height: launchConfiguration.windowSize.height
        )
    }
}
