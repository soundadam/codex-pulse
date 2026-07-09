import AppKit
import SwiftUI

@MainActor
public final class StatusBarController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var eventMonitor: Any?

    public init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 430, height: 320)
        popover.contentViewController = NSHostingController(
            rootView: InspectorRootView(model: model)
        )

        if let button = statusItem.button {
            button.title = model.statusTitle
            button.target = self
            button.action = #selector(togglePopover)
        }

        model.onStatusTitleChange = { [weak self] title in
            self?.statusItem.button?.title = title
        }
    }

    @objc
    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installEventMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeEventMonitor()
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                self.model.refreshNow()
                return nil
            }

            switch event.keyCode {
            case 53:
                self.closePopover()
                return nil
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
