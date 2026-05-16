import SwiftUI

@MainActor
final class AppLifecycle: ObservableObject {
    private var scheduler: RefreshScheduler?

    func attach(to viewModel: AppViewModel) {
        guard scheduler == nil else { return }  // idempotent
        scheduler = RefreshScheduler(interval: 60) { [weak viewModel] in
            await viewModel?.refresh()
        }
        scheduler?.start()
    }
}
