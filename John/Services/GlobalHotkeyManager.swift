import AppKit
import Carbon

// Global Hotkey Manager using Carbon API for reliable system-wide hotkeys
class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()
    
    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var onHotkey: (() -> Void)?
    
    private init() {}
    
    func registerHotkey(modifiers: NSEvent.ModifierFlags, keyCode: UInt32, action: @escaping () -> Void) {
        // Unregister existing hotkey
        unregisterHotkey()
        
        self.onHotkey = action
        
        // Convert NSEvent modifiers to Carbon modifiers
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        
        // Install event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        let handlerCallback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard userData != nil else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onHotkey?()
            }
            return noErr
        }
        
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerCallback,
            1,
            &eventType,
            selfPointer,
            &hotkeyHandler
        )
        
        guard status == noErr else {
            print("Failed to install event handler: \(status)")
            return
        }
        
        // Register the hotkey
        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x4A4F484B) // "JOHK"
        hotkeyID.id = 1
        
        let registerStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotkeyID,
            GetEventDispatcherTarget(),
            0,
            &hotkeyRef
        )
        
        guard registerStatus == noErr else {
            print("Failed to register hotkey: \(registerStatus)")
            if let handler = hotkeyHandler {
                RemoveEventHandler(handler)
                hotkeyHandler = nil
            }
            return
        }
        
        print("Global hotkey registered successfully")
    }
    
    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = hotkeyHandler {
            RemoveEventHandler(handler)
            hotkeyHandler = nil
        }
        onHotkey = nil
    }
    
    deinit {
        unregisterHotkey()
    }
}