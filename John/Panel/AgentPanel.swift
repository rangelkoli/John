import AppKit
import SwiftUI

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class AgentPanel: NSPanel {
    private let harness: AgentHarness
    private var notchWindow: NotchWindow?
    
    init(harness: AgentHarness) {
        self.harness = harness
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        minSize = NSSize(width: 480, height: 400)
        maxSize = NSSize(width: 900, height: 800)
        
        let contentView = PanelContentView(
            harness: harness,
            onClose: { [weak self] in self?.hidePanel() }
        )
        let hosting = ClickThroughHostingView(rootView: contentView)
        self.contentView = hosting
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func setNotchWindow(_ notchWindow: NotchWindow) {
        self.notchWindow = notchWindow
    }
    
    func showPanel(below rect: NSRect) {
        harness.resetConversation()
        if let screen = NSScreen.main {
            let panelWidth = frame.width
            let panelHeight = frame.height
            let x = rect.midX - panelWidth / 2
            let y = screen.visibleFrame.maxY - panelHeight
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .JohnStatusChanged, object: nil)
    }
    
    func showPanelWithoutReset() {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth = frame.width
            let panelHeight = frame.height
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - panelHeight
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .JohnStatusChanged, object: nil)
    }
    
    func showPanelCentered(on screen: NSScreen) {
        harness.resetConversation()
        let screenFrame = screen.frame
        let panelWidth = frame.width
        let panelHeight = frame.height
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .JohnStatusChanged, object: nil)
    }
    
    func hidePanel() {
        orderOut(nil)
    }
    
    func focusInput() {
        makeKeyAndOrderFront(nil)
        // Post notification to focus input
        NotificationCenter.default.post(name: .FocusInput, object: nil)
    }
    
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        alphaValue = 1.0
    }
    
    @objc private func windowDidResignKey(_ notification: Notification) {
        alphaValue = 0.95
    }
    
    override func sendEvent(_ event: NSEvent) {
        let wasKey = isKeyWindow
        super.sendEvent(event)
        if !wasKey && event.type == .leftMouseDown {
            super.sendEvent(event)
        }
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            hidePanel()
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
            showSettings()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    
    private func showSettings() {
        let settingsView = SettingsView(harness: harness)
        let settingsPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsPanel.title = "John Settings"
        settingsPanel.contentView = NSHostingView(rootView: settingsView)
        settingsPanel.makeKeyAndOrderFront(nil)
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}