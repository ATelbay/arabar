import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let viewModel: AppViewModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var hostingView: NSHostingView<MenuBarLabel>?
    private var sizeCancellables: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureButton()
        configurePopover()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let hosting = NSHostingView(rootView: MenuBarLabel(viewModel: viewModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])
        hostingView = hosting

        // Drive status-item width from SwiftUI's intrinsic size. Without this the button
        // stays at default width and the percent text gets clipped.
        // `fittingSize` is not KVO-observable, so re-measure whenever the label's inputs
        // change: view-model publishes (percent, rotation) and @AppStorage visibility toggles.
        // objectWillChange fires before SwiftUI re-renders, hence the hop to the next run loop.
        updateLength()
        viewModel.objectWillChange
            .merge(with: NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateLength() }
            }
            .store(in: &sizeCancellables)

        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateLength() {
        guard let hosting = hostingView else { return }
        let width = max(hosting.fittingSize.width.rounded(.up), 24)
        if statusItem.length != width { statusItem.length = width }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(viewModel: viewModel)
        )
    }

    @objc private func handleClick(_ sender: Any?) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            // Right-click (two-finger tap): cycle provider in the menubar
            viewModel.rotationIndex &+= 1
            return
        }
        togglePopover()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Refresh on open so a just-completed browser re-login is reflected immediately
            // instead of waiting up to the 60s timer tick.
            Task { await viewModel.refresh() }
        }
    }
}
