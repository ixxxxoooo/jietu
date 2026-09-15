import AppKit
import Carbon.HIToolbox

/// 基于 Carbon `RegisterEventHotKey` 的全局热键中心。
///
/// 选 Carbon 而不是 `NSEvent.addGlobalMonitor` 的原因：Carbon 热键无需「辅助功能」
/// 权限，也不需要在 app 未激活时轮询所有键盘事件。
final class HotkeyCenter {
    private struct Entry {
        let hotkey: Hotkey
        let action: () -> Void
        let ref: EventHotKeyRef
    }

    private var eventHandler: EventHandlerRef?
    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var isHandlerInstalled = false

    @discardableResult
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[Jietu] RegisterEventHotKey failed (status=\(status)) for \(hotkey.displayString)")
            return nil
        }

        entries[id] = Entry(hotkey: hotkey, action: action, ref: ref)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    func unregisterAll() {
        for entry in entries.values {
            UnregisterEventHotKey(entry.ref)
        }
        entries.removeAll()
    }

    fileprivate func perform(id: UInt32) {
        entries[id]?.action()
    }

    private func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            jietuHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            NSLog("[Jietu] InstallEventHandler failed (status=\(status))")
            return
        }
        isHandlerInstalled = true
    }

    /// 'JTU1'
    private static let signature: OSType = 0x4A545531
}

/// Carbon 回调是 C 函数指针，不能捕获上下文，因此用 `userData` 把 self 传进来。
///
/// 全局热键由主 run loop 分发，所以这里可以安全地 `assumeIsolated`。
private nonisolated func jietuHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.perform(id: hotKeyID.id)
    }
    return noErr
}
