import AppKit
import SwiftUI

enum InspectorPanelLayout {
    static let preferredContentSize = CGSize(width: 780, height: 560)

    private static let chromeAllowance = CGSize(width: 32, height: 48)

    static func contentSize(for visibleFrame: CGRect) -> CGSize {
        let availableWidth = max(1, visibleFrame.width - chromeAllowance.width)
        let availableHeight = max(1, visibleFrame.height - chromeAllowance.height)
        return CGSize(
            width: min(preferredContentSize.width, availableWidth),
            height: min(preferredContentSize.height, availableHeight)
        )
    }
}

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
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = InspectorPanelLayout.preferredContentSize

        if let button = statusItem.button {
            configure(button)
            update(button, title: model.statusTitle)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        model.onStatusTitleChange = { [weak self] title in
            guard let button = self?.statusItem.button else {
                return
            }
            self?.update(button, title: title)
        }

        #if DEBUG
        let capturePath = ProcessInfo.processInfo.environment["CODEXIQ_CAPTURE_PATH"]
        if ProcessInfo.processInfo.environment["CODEXIQ_SHOW_POPOVER"] == "1"
            || capturePath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPopover()
            }
        }
        if let capturePath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.capturePopover(to: capturePath)
            }
        }
        #endif
    }

    private func configure(_ button: NSStatusBarButton) {
        let symbol = NSImage(
            systemSymbolName: "waveform.path.ecg",
            accessibilityDescription: "CodexIQ"
        )
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = symbol?.withSymbolConfiguration(configuration) ?? symbol
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
    }

    private func update(_ button: NSStatusBarButton, title: String) {
        let accessibilityLabel = StatusItemTitleFormatter.accessibilityLabel(for: title)
        button.title = ""
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
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

        let visibleFrame = button.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: InspectorPanelLayout.preferredContentSize)
        let contentSize = InspectorPanelLayout.contentSize(for: visibleFrame)

        model.setPopoverVisible(true)
        popover.contentSize = contentSize
        popover.contentViewController = NSHostingController(
            rootView: InspectorRootView(model: model, contentSize: contentSize)
        )

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
        model.setPopoverVisible(false)
        // Releasing the hosting controller tears down Swift Charts and its
        // retained Canvas/IOSurface backing stores while the panel is closed.
        popover.contentViewController = nil
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

    #if DEBUG
    private func capturePopover(to path: String) {
        guard let view = popover.contentViewController?.view else {
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    #endif

}
