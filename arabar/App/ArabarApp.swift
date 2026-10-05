import SwiftUI
import AppKit

@main
struct ArabarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("arabar Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = AppViewModel()
    let lifecycle = AppLifecycle()
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(viewModel: viewModel)
        lifecycle.attach(to: viewModel)
        // A sole `Window` scene is presented at launch (including as a Login Item).
        // `.defaultLaunchBehavior(.suppressed)` needs macOS 15, so close it once here;
        // "Settings…" reopens it through openWindow(id:).
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("settings") == true {
                window.close()
            }
        }
    }

    // SwiftUI's Window scene defaults to quitting the app when the last window closes,
    // even for LSUIElement menubar apps. Closing the Settings window must not terminate.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
