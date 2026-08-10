import Carbon.HIToolbox
import Foundation

/// 全局热键：F10（隐藏态双击呼出 / 可见态单击收起）
/// 使用 Carbon RegisterEventHotKey —— 不需要辅助功能 / 输入监控权限
/// 选 F10：Firefox(F7 光标浏览)、VS Code(F8/F9/F12)、Excel(F9 重算/F4 绝对引用) 均无冲突
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private let hotKeySignature: OSType = 0x46313047 // "F10G"

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, _, _ -> OSStatus in
            HotkeyManager.shared.onPress?()
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        if installStatus != noErr {
            NSLog("Mirrage: InstallEventHandler failed \(installStatus)")
        }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_F10), 0, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if regStatus != noErr {
            NSLog("Mirrage: RegisterEventHotKey failed \(regStatus)")
        }
    }
}
