import AppKit
import Carbon.HIToolbox
import Foundation

/// 全局热键：呼出键 + 收起键，可在设置面板里各自录制。
/// 使用 Carbon RegisterEventHotKey —— 不需要辅助功能 / 输入监控权限。
/// 默认两个都是 F10（kVK_F10=109），保留旧语义：隐藏态双击呼出 / 可见态单击收起；
/// 录成不同的键后各按一次即生效。
///
/// 选 F 键的原因：Firefox(F7 光标浏览)、VS Code(F8/F9/F12)、Excel(F9 重算/F4 绝对引用)
/// 均无冲突；普通字符键会被 RegisterEventHotKey 注册成全局热键，打字时会误触
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// 按下某个热键（参数 = kVK keyCode + Carbon 修饰键掩码；修饰键已由 Carbon 匹配）
    var onPress: ((_ keyCode: Int, _ modifiers: Int) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var idToHotkey: [Int: (keyCode: Int, modifiers: Int)] = [:]
    private var nextID = 1
    private let hotKeySignature: OSType = 0x4D697252 // "MirR"

    init() {
        // 事件处理器只装一次：重复 InstallEventHandler 会让同一个热键回调 N 次
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
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
            guard status == noErr else { return noErr }
            if let hk = HotkeyManager.shared.idToHotkey[Int(hotKeyID.id)] {
                HotkeyManager.shared.onPress?(hk.keyCode, hk.modifiers)
            }
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
    }

    /// 注销旧的、注册新的（相同 keyCode+mods 组合只注册一次——Carbon 拒绝重复注册）。
    /// 幂等，设置改动后直接调
    func register(_ hotkeys: [(keyCode: Int, modifiers: Int)]) {
        unregister()
        var seen = Set<String>()
        for hk in hotkeys {
            let key = "\(hk.keyCode)-\(hk.modifiers)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySignature, id: UInt32(nextID))
            let status = RegisterEventHotKey(
                UInt32(hk.keyCode), UInt32(hk.modifiers), id,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr {
                idToHotkey[nextID] = hk
                nextID += 1
                if let ref { hotKeyRefs.append(ref) }
            } else {
                NSLog("Mirrage: RegisterEventHotKey(\(hk.keyCode)) failed \(status)")
            }
        }
    }

    private func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        idToHotkey.removeAll()
    }
}

// MARK: - 键名显示与合法性

enum HotkeyName {
    /// kVK keyCode → 人类可读键名（只覆盖常见的，够用）
    static func keyName(_ code: Int) -> String? {
        switch code {
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }

    /// 完整显示名：修饰键符号 + 键名，如 "⌃⌥⇧⌘F10"；认不出就回退 keyCode 数字
    static func name(keyCode: Int, modifiers: Int) -> String {
        var parts: [String] = []
        if modifiers & Int(controlKey) != 0 { parts.append("⌃") }
        if modifiers & Int(optionKey) != 0 { parts.append("⌥") }
        if modifiers & Int(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & Int(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(keyCode) ?? "\(keyCode)")
        return parts.joined()
    }

    /// 这个键能不能当全局热键：
    /// - 无修饰的普通键（字母/数字/标点/Return/Tab/Esc/Space/方向键）一律拒绝——
    ///   全局热键在打字时也会触发，会吃字
    /// - F 键永远可以
    /// - 带修饰键的组合只拒绝 App 自己已经占用的（⌘T / ⌘. / ⌘+Enter / 任何 Esc/Tab 组合）
    static func isValid(keyCode: Int, modifiers: Int) -> Bool {
        let mods = modifiers
        // App 占用（本地监听会吃掉这些键，注册成热键会打架）
        if keyCode == 53 { return false }                    // Esc 及任何组合
        if keyCode == 48 { return false }                    // Tab 及任何组合
        if mods == 0 {
            // 无修饰：只有 F 键安全
            return keyName(keyCode)?.hasPrefix("F") ?? false
        }
        if keyCode == 36 && mods & Int(cmdKey) != 0 { return false }   // ⌘+Enter
        if keyCode == 47 && mods & Int(cmdKey) != 0 { return false }   // ⌘.
        if keyCode == 17 && mods & Int(cmdKey) != 0 { return false }   // ⌘T
        return true
    }

    /// NSEvent 修饰键 → Carbon 掩码
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.control) { m |= Int(controlKey) }
        if flags.contains(.option) { m |= Int(optionKey) }
        if flags.contains(.shift) { m |= Int(shiftKey) }
        if flags.contains(.command) { m |= Int(cmdKey) }
        return m
    }
}
