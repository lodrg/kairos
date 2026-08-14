import AppKit
import Carbon.HIToolbox
import Foundation

/// 全局热键：唯一的呼出键，可在设置面板里录制；收起永远是 Esc（App 内部处理）。
/// 使用 Carbon RegisterEventHotKey —— 不需要辅助功能 / 输入监控权限。
///
/// 冲突处理：如果某个键已经被别的 App 全局注册，RegisterEventHotKey 会返回
/// eventHotKeyExistsErr——不再静默忽略，而是记进 failedKeys 交给 UI 提示用户重录。
/// （选带修饰键的组合做默认值，就是为尽量少撞上这种冲突，见 Settings 的注释）
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// 按下热键（参数 = kVK keyCode + Carbon 修饰键掩码；修饰键已由 Carbon 匹配）
    var onPress: ((_ keyCode: Int, _ modifiers: Int) -> Void)?

    /// 上一次 register 里注册失败的键（通常是被其他 App 占用的全局热键）。
    /// 设置面板 / 首启引导据此显示冲突警告
    private(set) var failedKeys: [(keyCode: Int, modifiers: Int)] = []

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
            HotkeyManager.debugLog("carbon handler got id=\(hotKeyID.id)")
            if let hk = HotkeyManager.shared.idToHotkey[Int(hotKeyID.id)] {
                HotkeyManager.debugLog("carbon dispatch keyCode=\(hk.keyCode) mods=\(hk.modifiers)")
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
            NSLog("Kairos: InstallEventHandler failed \(installStatus)")
        }
    }

    /// 注销旧的、注册新的（相同 keyCode+mods 组合只注册一次——Carbon 拒绝重复注册）。
    /// 幂等，设置改动后直接调。注册失败的键记进 failedKeys，供 UI 显示冲突
    func register(_ hotkeys: [(keyCode: Int, modifiers: Int)]) {
        unregister()
        failedKeys = []
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
                NSLog("Kairos: RegisterEventHotKey(\(hk.keyCode)) failed \(status)")
                if status == OSStatus(eventHotKeyExistsErr) {
                    // 别的 App 已经占了这个键——这是用户可见的冲突，不是内部错误
                    failedKeys.append(hk)
                }
            }
        }
    }

    private func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        idToHotkey.removeAll()
    }

    /// 热键调试日志（NSLog 不进 unified log，App 的坑）——排查「录了没反应」
    static func debugLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [carbon] \(message)\n"
        if let handle = fopen("/tmp/kairos-hotkey.log", "a") {
            fputs(line, handle)
            fclose(handle)
        }
    }
}

// MARK: - 键名显示与合法性

enum HotkeyName {
    /// kVK keyCode → 人类可读键名（覆盖 F 键、特殊键 + ANSI 字母/数字/符号，
    /// 够用且足够准——旧版只有 F 键和少数特殊键，录制 ⌘S 会显示成「⌘1」）
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
        case 51: return "Delete"
        case 117: return "Forward Delete"
        case 76: return "Enter"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        // ANSI 字母（US 布局；大小写不区分，录的是键位不是字符）
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        // ANSI 数字 / 符号
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 27: return "-"
        case 24: return "="
        case 33: return "["
        case 30: return "]"
        case 42: return "\\"
        case 43: return ";"
        case 41: return "'"
        case 39: return ","
        case 47: return "."
        case 44: return "/"
        case 50: return "`"
        default: return nil
        }
    }

    /// 系统设置「将 F1、F2 等键用作标准功能键」是否关闭。
    /// 关着的时候裸 F 键是媒体键（F10=静音），按键根本到不了 App——
    /// 全局热键注册了也永远不触发。fnState 存全局域：1 = 标准功能键，0 或缺省 = 媒体键
    static func functionKeysAreMedia() -> Bool {
        !UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
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
