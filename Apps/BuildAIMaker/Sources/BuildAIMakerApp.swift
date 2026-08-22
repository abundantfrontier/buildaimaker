import AppKit
import BAMAudioFX
import SwiftUI

@main
struct BuildAIMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controlPlane = ControlPlaneEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controlPlane)
                .task {
                    await controlPlane.bootstrap()
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Ensures SPM-launched app behaves as a normal GUI app (key window, menu, Dock).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task.detached(priority: .utility) {
            await CatalogTTSRuntime.ensureReady()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
