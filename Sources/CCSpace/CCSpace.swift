import SwiftUI

@main
struct CCSpace: App {
    private let launchConfiguration = CCSpaceLaunchConfiguration()

    var body: some Scene {
        WindowGroup {
            RootSplitView(launchConfiguration: launchConfiguration)
        }
        .defaultSize(
            width: launchConfiguration.windowSize.width,
            height: launchConfiguration.windowSize.height
        )
    }
}
