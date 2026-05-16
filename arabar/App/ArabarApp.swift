import SwiftUI

@main
struct ArabarApp: App {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var lifecycle = AppLifecycle()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
                .onAppear { lifecycle.attach(to: viewModel) }
        }
        .menuBarExtraStyle(.window)

        Window("arabar Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
