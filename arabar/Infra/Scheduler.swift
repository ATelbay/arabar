import Foundation

@MainActor
final class RefreshScheduler {
    private var timer: Timer?
    private let interval: TimeInterval
    private let action: () async -> Void
    private var isRunning: Bool = false

    init(interval: TimeInterval = 60, action: @escaping () async -> Void) {
        self.interval = interval
        self.action = action
    }

    func start() {
        stop()
        // Fire immediately
        fireAction()
        // Schedule recurring ticks
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fireAction()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fireAction() {
        guard !isRunning else { return }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            await self.action()
            await MainActor.run { self.isRunning = false }
        }
    }
}
