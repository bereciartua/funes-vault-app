import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut for the global hotkey: a virtual key code and Carbon modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌥⌘M (FR-C-01).
    static let defaultCapture = Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey))
    /// ⌃⌥⌘R: Review Request, which brings the approval panel forward and makes it key (FR-D-03).
    /// Three modifiers, because ⌥⌘R is taken in Xcode and Safari.
    static let defaultReview = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey | controlKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press in the recorder; nil without ⌘, ⌥ or ⌃ (a plain key can't be global).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    /// "Control-Option-Command-R", for VoiceOver announcements.
    var spoken: String {
        var parts = [String]()
        if modifiers & UInt32(controlKey) != 0 { parts.append(String(localized: "Control")) }
        if modifiers & UInt32(optionKey) != 0 { parts.append(String(localized: "Option")) }
        if modifiers & UInt32(shiftKey) != 0 { parts.append(String(localized: "Shift")) }
        if modifiers & UInt32(cmdKey) != 0 { parts.append(String(localized: "Command")) }
        return (parts + [Self.keyName(keyCode)]).joined(separator: "-")
    }

    /// "⌥⌘M".
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The character the key types on the current layout, or a name for special keys.
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return String(localized: "Space")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        default: break
        }
        // Function keys' codes aren't in order.
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                            kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let index = functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// A global hotkey through Carbon's RegisterEventHotKey: it works from any app and needs no
/// Accessibility permission (FR-C-01). Each has its own id: a handler acts only on its own key and
/// passes the others on, so capture and Review Request never fire each other.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32
    private static let signature: OSType = 0x464E_5356  // "FNSV"

    /// `id`: 1 for capture, 2 for Review Request.
    init(id: UInt32 = 1, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            guard status == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }
            return noErr
        }, 1, &spec, context, &handler)
    }

    /// Registers `shortcut`, replacing the previous one. False when another app already has it.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        reference = ref
        return status == noErr
    }
}
