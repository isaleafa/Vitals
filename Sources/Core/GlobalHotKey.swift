import AppKit
import Carbon

private final class HotKeyCallbackBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

/// 全局快捷键管理器（基于 Carbon RegisterEventHotKey，免无障碍权限，原生轻量）
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callbackBox: HotKeyCallbackBox?

    private init() {}

    /// 设置并启用全局快捷键 ⌥V
    func setup(handler: @escaping () -> Void) {
        callbackBox = HotKeyCallbackBox(handler)
        let isEnabled = UserDefaults.standard.object(forKey: "enableGlobalHotKey") as? Bool ?? true
        if isEnabled {
            register()
        }
    }

    func updateRegistration(enabled: Bool) {
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKeyRef == nil, let box = callbackBox else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let ptr = Unmanaged.passUnretained(box).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event = event, let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if hotKeyID.signature == 0x56495441 && hotKeyID.id == 1 {
                    let targetBox = Unmanaged<HotKeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async { targetBox.action() }
                }
                return noErr
            },
            1,
            &eventType,
            ptr,
            &eventHandler
        )
        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: 0x56495441, id: 1) // "VITA"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}
