import AppKit
import SwiftUI

@MainActor
public final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var keyEventMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var lastPopoverCloseAt: Date?

    public init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 760, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: InspectorRootView(model: model)
        )

        if let button = statusItem.button {
            button.title = model.statusTitle
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        model.onStatusTitleChange = { [weak self] title in
            self?.statusItem.button?.title = title
        }
    }

    @objc
    private func togglePopover() {
        if let lastPopoverCloseAt,
           Date().timeIntervalSince(lastPopoverCloseAt) < 0.2 {
            return
        }

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

        let anchorRect = NSRect(
            x: max(0, button.bounds.midX - 2),
            y: button.bounds.minY,
            width: 4,
            height: button.bounds.height
        )

        popover.show(relativeTo: anchorRect, of: button, preferredEdge: .minY)
        installEventMonitors()
    }

    private func closePopover() {
        guard popover.isShown else {
            removeEventMonitors()
            return
        }
        popover.performClose(nil)
    }

    private func installEventMonitors() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
            case 125:
                self.model.moveSelection(offset: 1)
                return nil
            case 126:
                self.model.moveSelection(offset: -1)
                return nil
            case 36, 76:
                _ = self.model.openSelectedRollout()
                return nil
            default:
                return event
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }
            guard self.popover.isShown else {
                return event
            }
            if self.hitTestsPopoverOrStatusItem(event: event) {
                return event
            }
            self.closePopover()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self else {
                return
            }
            guard self.popover.isShown else {
                return
            }
            let point = NSEvent.mouseLocation
            if self.isScreenPointInsidePopover(point) || self.isScreenPointInsideStatusItem(point) {
                return
            }
            Task { @MainActor in
                self.closePopover()
            }
        }
    }

    private func removeEventMonitors() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseAt = Date()
        removeEventMonitors()
    }

    private func hitTestsPopoverOrStatusItem(event: NSEvent) -> Bool {
        let point: NSPoint
        if let window = event.window {
            point = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            point = NSEvent.mouseLocation
        }
        return isScreenPointInsidePopover(point) || isScreenPointInsideStatusItem(point)
    }

    private func isScreenPointInsidePopover(_ point: NSPoint) -> Bool {
        guard let window = popover.contentViewController?.view.window else {
            return false
        }
        return window.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    private func isScreenPointInsideStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button,
              let window = button.window else {
            return false
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        return rectOnScreen.insetBy(dx: -4, dy: -4).contains(point)
    }

}
