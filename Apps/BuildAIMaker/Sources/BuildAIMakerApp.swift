import SwiftUI
import BAMCore
import BAMResourcesUI

@main
struct BuildAIMakerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
