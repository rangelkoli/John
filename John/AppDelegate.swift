import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var agentPanel: AgentPanel!
    private var notchWindow: NotchWindow?
    
    let harness = AgentHarness()
    
    private var hoverHideTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    
    private var panelOpenedViaHover = false
    private let hoverMargin: CGFloat = 15
    private let hoverHideDelay: TimeInterval = 0.06
    
    private var showInNotch: Bool {
        get {
            if UserDefaults.standard.object(forKey: "showInNotch") == nil { return true }
            return UserDefaults.standard.bool(forKey: "showInNotch")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showInNotch")
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupAgentPanel()
        if showInNotch {
            setupNotchWindow()
        }
        setupHotkey()
        setupSettingsObserver()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "John") {
                button.image = image
                button.image?.isTemplate = true
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    private func setupAgentPanel() {
        agentPanel = AgentPanel(harness: harness)
        
        if let notchWindow {
            agentPanel.setNotchWindow(notchWindow)
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: agentPanel
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: agentPanel
        )
    }
    
    private func setupNotchWindow() {
        notchWindow = NotchWindow(onHover: { [weak self] in
            self?.notchHovered()
        }, harness: harness)
        notchWindow?.isPanelVisible = { [weak self] in
            self?.agentPanel.isVisible ?? false
        }
        
        agentPanel.setNotchWindow(notchWindow!)
    }
    
    private func setupHotkey() {
        // Local monitor for when app is active
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event: event)
            return event
        }
        
        // Global monitor for when app is in background
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event: event)
        }
    }
    
    private func handleHotkey(event: NSEvent) {
        // Space key code is 49
        guard event.keyCode == 49 else { return }
        
        // Check for Command + Shift
        let flags = event.modifierFlags
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        
        guard hasCommand && hasShift else { return }
        
        // Toggle panel
        DispatchQueue.main.async { [weak self] in
            self?.togglePanelAndFocus()
        }
    }
    
    private func togglePanelAndFocus() {
        if agentPanel.isVisible {
            agentPanel.hidePanel()
            notchWindow?.endHover()
            panelOpenedViaHover = false
            stopHoverTracking()
        } else {
            stopHoverTracking()
            panelOpenedViaHover = false
            showPanelBelowStatusItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.agentPanel.focusInput()
            }
        }
    }
    
    private func setupSettingsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsPanel),
            name: .ShowSettings,
            object: nil
        )
    }
    
    @objc private func showSettingsPanel() {
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.title == "John Settings" }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let settingsView = SettingsView(harness: harness)
        let hostingView = NSHostingView(rootView: settingsView)
        
        let settingsPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsPanel.title = "John Settings"
        settingsPanel.contentView = hostingView
        settingsPanel.center()
        settingsPanel.isFloatingPanel = true
        settingsPanel.level = .floating
        settingsPanel.hidesOnDeactivate = false
        settingsPanel.makeKeyAndOrderFront(nil)
    }
    
    private func notchHovered() {
        guard !agentPanel.isVisible else { return }
        showPanelBelowNotch()
        panelOpenedViaHover = true
        startHoverTracking()
    }
    
    private func showPanelBelowNotch() {
        guard let screen = NSScreen.builtIn else { return }
        agentPanel.showPanelCentered(on: screen)
    }
    
    private func startHoverTracking() {
        stopHoverTracking()
        
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkHoverBounds()
        }
        
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkHoverBounds()
            return event
        }
    }
    
    private func stopHoverTracking() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
        
        if let monitor = hoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMonitor = nil
        }
        if let monitor = hoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMonitor = nil
        }
    }
    
    private func checkHoverBounds() {
        let mouse = NSEvent.mouseLocation
        let inNotch = notchWindow?.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse) ?? false
        let inPanel = agentPanel.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse)
        
        if inNotch || inPanel {
            cancelHoverHide()
        } else {
            scheduleHoverHide()
        }
    }
    
    private func scheduleHoverHide() {
        guard hoverHideTimer == nil else { return }
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: hoverHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let inNotch = self.notchWindow?.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) ?? false
            let inPanel = self.agentPanel.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse)
            
            if !inNotch && !inPanel {
                self.agentPanel.hidePanel()
                self.notchWindow?.endHover()
                self.panelOpenedViaHover = false
                self.stopHoverTracking()
            }
        }
    }
    
    private func cancelHoverHide() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showContextMenu()
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        
        let notchItem = NSMenuItem(
            title: "Show in notch",
            action: #selector(toggleShowInNotch),
            keyEquivalent: ""
        )
        notchItem.target = self
        notchItem.state = showInNotch ? .on : .off
        menu.addItem(notchItem)
        
        menu.addItem(.separator())
        
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsPanel),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(.separator())
        
        let newItem = NSMenuItem(
            title: "New Conversation",
            action: #selector(newConversation),
            keyEquivalent: "n"
        )
        newItem.target = self
        menu.addItem(newItem)
        
        let toggleItem = NSMenuItem(
            title: "Toggle Panel",
            action: #selector(togglePanelFromMenu),
            keyEquivalent: " "
        )
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(
            title: "Quit John",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    
    @objc private func togglePanelFromMenu() {
        togglePanelAndFocus()
    }
    
    @objc private func toggleShowInNotch() {
        showInNotch.toggle()
        if showInNotch {
            setupNotchWindow()
        } else {
            notchWindow?.orderOut(nil)
            notchWindow = nil
        }
    }
    
    @objc private func newConversation() {
        harness.resetConversation()
        showPanelBelowStatusItem()
    }
    
    private func showPanelBelowStatusItem() {
        guard let button = statusItem.button,
              let window = button.window else { return }
        
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        agentPanel.showPanel(below: screenRect)
    }
    
    @objc private func windowDidResignKey(_ notification: Notification) {
        guard !panelOpenedViaHover else { return }
        notchWindow?.endHover()
        stopHoverTracking()
    }
    
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        if panelOpenedViaHover {
            panelOpenedViaHover = false
            stopHoverTracking()
        }
    }
}