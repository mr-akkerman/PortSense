// PortSense — shows your Mac's ports, what is plugged in, link speed and power.
// Lives in the menu bar. Build: ./scripts/build.sh

import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PortSense: could not toggle launch at login: \(error)")
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = Store()
    private var item: NSStatusItem!
    private var panel: FloatingPanel!
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var outsideSince: Date?
    private var pinned = false
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.registerDefaults()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addTrackingArea(NSTrackingArea(rect: .zero,
                                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self))
        }

        panel = FloatingPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PanelView(store: store))

        store.onChange = { [weak self] in self?.updateIcon() }
        store.openSettings = { [weak self] in self?.showSettings() }
        updateIcon()
        store.refresh()

        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.bool(forKey: Pref.notifySlow) || UserDefaults.standard.bool(forKey: Pref.notifyConnect) {
            store.requestNotificationPermission()
        }

        // A click in any other app, or switching to it, closes the panel — even a pinned one.
        // Clicks on the panel itself and on the status item never reach this monitor.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.hidePanel()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.hidePanel()
            }
        }
        // Polling is cheap (straight from IORegistry), so we watch continuously for notifications and history.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
    }

    // Show notifications even while the app counts as active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        let busy = store.occupiedCount
        let slow = store.ports.contains { $0.hasSlowDevice }
        let image = NSImage(systemSymbolName: busy > 0 ? "cable.connector" : "cable.connector.slash",
                            accessibilityDescription: "PortSense")
            ?? NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: "PortSense")
        image?.isTemplate = true
        button.image = image
        let text = store.menuBarText
        button.title = text.isEmpty ? "" : " \(text)"
        button.toolTip = slow ? L("Есть медленное подключение", "A device is on a slow connection") : nil
    }

    // Hovering the status item
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { showPanel() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) {}

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: L("Обновить", "Refresh"), action: #selector(refreshNow), keyEquivalent: "r").target = self
            menu.addItem(withTitle: L("Настройки…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
            let login = menu.addItem(withTitle: L("Запускать при входе", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.enabled ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            hidePanel()
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        // A click pins the panel, a second click dismisses it.
        pinned.toggle()
        if pinned { showPanel() } else { hidePanel() }
    }

    @objc private func refreshNow() { store.refresh() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.enabled) }

    @objc private func showSettings() {
        hidePanel()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(store: store))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            settingsWindow = w
        }
        settingsWindow?.title = "PortSense — " + L("Настройки", "Settings")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showPanel() {
        guard let button = item.button, let window = button.window else { return }
        store.refresh()
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView!.fittingSize
        let screen = window.screen ?? NSScreen.main!
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - size.width - 6)
        let y = buttonFrame.minY - size.height + panelEdge - 4
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        outsideSince = nil
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
    }

    /// Hide the panel once the pointer has been outside the icon and the visible content for 0.3 s.
    private func checkMouse() {
        guard !pinned, let button = item.button, let window = button.window else { return }
        let mouse = NSEvent.mouseLocation
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -2, dy: -4)
        let r = store.contentRect
        let content = NSRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY,
                             width: r.width, height: r.height).insetBy(dx: -6, dy: -6)
        // A bridge between the icon and the panel so the pointer does not "fall through" on the way.
        let bridge = NSRect(x: min(buttonFrame.minX, content.minX), y: content.maxY - 2,
                            width: max(buttonFrame.maxX, content.maxX) - min(buttonFrame.minX, content.minX),
                            height: buttonFrame.minY - content.maxY + 4)
        if buttonFrame.contains(mouse) || content.contains(mouse) || bridge.contains(mouse) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.3 { hidePanel() }
        } else {
            outsideSince = Date()
        }
    }

    private func hidePanel() {
        pinned = false
        pollTimer?.invalidate()
        pollTimer = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.store.hoveredID = nil
                self.store.ejectMessage = nil
            }
        })
    }
}

@main
enum PortSenseApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}
