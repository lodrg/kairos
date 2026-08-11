import AppKit
import Combine
import SwiftUI

/// 无边框、可成为 Key 的全屏覆盖窗口
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GoalStore()
    private let model = OverlayModel()
    private let settingsStore = SettingsStore()
    private var windows: [NSWindow] = []
    private var statusItem: NSStatusItem?

    private var isVisible = false
    private var lastPress = Date.distantPast
    /// 双击判定窗口：双击 F10 呼出；可见时单击 F10 或 Esc 收起
    private let doubleTapInterval: TimeInterval = 0.45
    private var checkInScanTimer: Timer?
    /// 语言切换后重建菜单栏菜单（NSMenu 是 AppKit 的，不随 SwiftUI 自动重绘）
    private var languageCancellable: AnyCancellable?
    /// 热键改动后重注册 Carbon 热键
    private var hotkeyCancellable: AnyCancellable?
    /// 透明模式改动后刷新窗口属性
    private var transparentCancellable: AnyCancellable?
    /// 面板/历史/签到/重选时长开关时刷新点击穿透（这些界面需要人点）
    private var modalCancellables: [AnyCancellable] = []
    /// 四个全屏界面的实时开关状态——由 sink 参数记录（不能反查 model，见上面注释）
    private struct ModalFlags {
        var settings = false
        var history = false
        var checkIn = false
        var retime = false
    }
    private var modalFlags = ModalFlags()
    /// 第一个覆盖窗口的根视图：签到的键盘动作统一走这里执行，
    /// 完成/延后/放弃的动画逻辑只有 OverlayView 里那一份实现，不在这里复制
    private var overlayView: OverlayView?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindows()
        setupStatusItem()
        installKeyMonitor()
        startCheckInScanning()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        HotkeyManager.shared.onPress = { [weak self] keyCode, modifiers in
            self?.handleHotkey(keyCode: keyCode, modifiers: modifiers)
        }
        hotkeyManagerRegister()

        // 语言切换后菜单栏菜单（AppKit 的）不会自动重绘，这里订阅重建
        languageCancellable = settingsStore.$settings
            .map(\.language)
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildMenu() }
            }

        // 热键改动即时重注册（录完一个键面板里立刻生效）
        hotkeyCancellable = settingsStore.$settings
            .map { ($0.showHotkeyKeyCode, $0.showHotkeyModifiers, $0.hideHotkeyKeyCode, $0.hideHotkeyModifiers) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hotkeyManagerRegister() }
            }

        // 透明模式即时生效（截图/点击穿透是窗口属性，改了马上刷到所有窗口）
        transparentCancellable = settingsStore.$settings
            .map(\.transparentMode)
            .removeDuplicates()
            .dropFirst() // 启动时的初始值由 buildWindows 后的 applyTransparentMode 处理
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTransparentMode() }
            }
        applyTransparentMode()

        // 面板/历史/签到卡/重选时长 开关时，点击穿透要跟着变：
        // 这些界面在覆盖层窗口里，穿透开着它们就点不了了（透明模式的经典坑）。
        // 不用 MergeMany——它的变参 init 要求所有 publisher 同类型，混入 map 会崩编译器。
        // 注意：@Published 在 willSet 阶段就派发，sink 参数是新值，但此刻反查属性
        // 还是旧值——必须记录 sink 参数，不能在回调里读 model（实测踩过）
        let applyClick: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.applyWindowClickThrough() }
        }
        modalCancellables = [
            model.$showSettings.sink { [weak self] v in self?.modalFlags.settings = v; applyClick() },
            model.$showHistory.sink { [weak self] v in self?.modalFlags.history = v; applyClick() },
            model.$pendingCheckInID.sink { [weak self] v in self?.modalFlags.checkIn = v != nil; applyClick() },
            model.$retimingGoalID.sink { [weak self] v in self?.modalFlags.retime = v != nil; applyClick() }
        ]

        // 调试入口：Mirrage --show / --hide / --show-settings / --show-arming
        // 后两个是给「只能用键盘到达的状态」留的口子：远程或没有辅助功能权限时，
        // 没法真的按 ⌘. / ⌘T，只能靠启动参数把那个状态摆出来看一眼
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.show() }
        } else if CommandLine.arguments.contains("--hide") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hide() }
        } else if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.show()
                self?.model.showSettings = true
            }
        } else if CommandLine.arguments.contains("--show-arming") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.show()
                self.model.draftMinutesIndex = 3
                self.model.isChoosingDuration = true
            }
        } else if CommandLine.arguments.contains("--show-retime") {
            // 调试：直接摆出全屏重选时长界面（--show-retime <目标ID>）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if let idx = CommandLine.arguments.firstIndex(of: "--show-retime"),
                   CommandLine.arguments.indices.contains(idx + 1),
                   let id = UUID(uuidString: CommandLine.arguments[idx + 1]) {
                    self.show()
                    self.model.retimingGoalID = id
                    self.model.isChoosingDuration = true
                    self.model.armingTargetID = id
                    self.model.draftMinutesIndex = 1 // 3m 预设，和真实流程的默认一致
                }
            }
        } else if !settingsStore.settings.onboardingSeen {
            // 首启引导：自动呼出 + 摆出引导卡（一生一次；回车/Esc/收起键看过即标记，
            // 之后再也不会弹——隐身优先，任何常驻提示都会暴露这是个热键 App）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.show()
                self.model.showOnboarding = true
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 窗口（每个屏幕一块）

    private func buildWindows() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.alphaValue = 0
            // 不在这里挂 contentView：启动即隐藏时图层树（~33MB IOSurface）会白挂着，
            // 等首次 show() 再懒重建——常驻隐藏态的内存最小化
            windows.append(window)
        }
    }

    /// 接显示器 / 拔显示器后重建覆盖窗口。原来窗口只在启动时建一次，
    /// 之后新接的屏幕没有覆盖层，拔掉的屏幕留下一块野窗口。
    @objc private func screensChanged() {
        let wasVisible = isVisible
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        buildWindows()
        applyTransparentMode() // 新窗口要重新落透明模式的窗口属性
        if wasVisible {
            isVisible = false
            show()
        }
    }


    // MARK: - 显示 / 隐藏（渐变动画）

    func show() {
        guard !isVisible else { return }
        isVisible = true

        for window in windows {
            // 注意：contentView 的 getter 会惰性自动创建空 NSView，永远 != nil——
            // 必须用「是不是我们的 NSHostingView」来判断是否已构建
            if !(window.contentView is NSHostingView<OverlayView>) {
                // 收起时释放过图层树（见 hide()）——呼出时重建，overlayView 必须指向新实例
                let content = OverlayView(store: store, model: model, settingsStore: settingsStore)
                overlayView = content
                window.contentView = NSHostingView(rootView: content)
            }
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        // 倒计时到期弹出签到卡片是要打断用户——必须抢到键盘焦点，D/K/S/X 才收得到。
        // 已实测：用户正在 WeChat 打字时，macOS 14+ 的 NSApp.activate() 不会抢前台，
        // 按键全部落进被盖住的 App；旧 API activateIgnoringOtherApps 仍能强制
        NSApp.activate()
        forceActivate()
        (windows.first { $0.screen == NSScreen.main } ?? windows.first)?.makeKey()

        // animatedIn 不包在 withAnimation 里：每行自己用 .animation(_:value:) 带着
        // 错峰延迟响应这次变化，外面再套一层事务反而会盖掉行级的时序
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.model.animatedIn = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.Duration.reveal
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for window in self.windows {
                    window.animator().alphaValue = 1.0
                }
            }
        }
    }

    /// 收起时不播内容动画：窗口整体淡出，等透明了再把 animatedIn 复位。
    /// 内容一边往下缩一边淡出会显得拖沓，而且和窗口淡出是两个时钟。
    ///
    /// 签到未决时整个函数直接不做（除非配置里打开了 checkInEscDismisses，让 F10
    /// 能直接关掉签到卡片）——这是唯一的收起入口（单击 F10 / 菜单栏 Show/Hide 都走这里）
    func hide() {
        let checkInBlocksHide = model.pendingCheckInID != nil && !settingsStore.settings.checkInEscDismisses
        guard isVisible, !checkInBlocksHide else { return }
        isVisible = false
        // 引导卡开着时按收起键退出 = 看过引导了，标记一生一次
        if model.showOnboarding { settingsStore.settings.onboardingSeen = true }
        // 配置允许的话，直接收起就相当于关掉签到卡片本身——不算 Done/Snooze 等任何动作
        model.pendingCheckInID = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.Duration.dismiss
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windows {
                window.animator().alphaValue = 0
            }
        }) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                for window in self.windows {
                    window.orderOut(nil)
                    // 释放整棵图层树（全屏窗口的 IOSurface 后备存储约 33MB）——
                    // 常驻隐藏态是绝大多数时间，内存减半；呼出时 show() 懒重建。
                    // 图层树是窗口唯一的内存大头，不释放就白挂着
                    window.contentView = nil
                }
                self.overlayView = nil
                self.model.animatedIn = false
                self.model.resetTransient()
            }
        }
    }

    /// 强制抢键盘焦点。macOS 14 把 `activateIgnoringOtherApps(_:)` 标成弃用（改名），
    /// 但新版 `activate()` 在用户正打字时不会抢前台（已实测）。用 selector 动态派发
    /// 调用旧 API——编译期完全不知道方法名，既不报错也不警告，运行时行为不变。
    private func forceActivate() {
        let selector = NSSelectorFromString("activateIgnoringOtherApps:")
        if NSApp.responds(to: selector) {
            _ = NSApp.perform(selector, with: NSNumber(value: true))
        } else {
            NSApp.activate()
        }
    }

    // MARK: - 热键逻辑

    /// 两个热键的语义：
    /// - 呼出键 == 收起键（默认 F10）：隐藏态双击呼出（0.45s 判定窗）、可见态单击收起
    /// - 呼出键 != 收起键：各按一次即生效（呼出键在可见态、收起键在隐藏态 = 无操作）
    /// 录制热键时忽略一切热键回调（录 F10 不该顺便把覆盖层弹出来/收掉）
    private func handleHotkey(keyCode: Int, modifiers: Int) {
        guard model.recordingHotkey == nil else { return }
        let s = settingsStore.settings
        let isShowKey = keyCode == s.showHotkeyKeyCode && modifiers == s.showHotkeyModifiers
        let isHideKey = keyCode == s.hideHotkeyKeyCode && modifiers == s.hideHotkeyModifiers

        if isShowKey && isHideKey {
            if isVisible {
                hide() // 可见时，单击即收起
                return
            }
            let now = Date()
            if now.timeIntervalSince(lastPress) < doubleTapInterval {
                lastPress = .distantPast
                show() // 双击呼出
            } else {
                lastPress = now
            }
        } else if isShowKey {
            if !isVisible { show() }
        } else if isHideKey {
            if isVisible { hide() }
        }
    }

    /// 首启引导卡关闭：回车=留在覆盖层开始用；Esc=关掉并收起。两种都标记 seen，
    /// 引导一生只出现一次
    private func dismissOnboarding(hide: Bool) {
        model.showOnboarding = false
        settingsStore.settings.onboardingSeen = true
        if hide { self.hide() }
    }

    private func hotkeyManagerRegister() {
        let s = settingsStore.settings
        HotkeyManager.shared.register([
            (keyCode: s.showHotkeyKeyCode, modifiers: s.showHotkeyModifiers),
            (keyCode: s.hideHotkeyKeyCode, modifiers: s.hideHotkeyModifiers)
        ])
    }

    /// 面板里录热键：Esc 取消；合法键写进 settings（didSet 自动 save + 订阅重注册）；
    /// 不合法键显示原因、继续录。录制时所有键都被吃掉，避免「录 F10 时还触发其他操作」
    private func handleHotkeyRecording(_ event: NSEvent) {
        guard let target = model.recordingHotkey else { return }
        let code = Int(event.keyCode)
        let mods = HotkeyName.carbonModifiers(from: event.modifierFlags)
        if code == 53 && mods == 0 { // Esc 取消
            model.recordingHotkey = nil
            model.hotkeyRejectMessage = nil
            return
        }
        guard HotkeyName.isValid(keyCode: code, modifiers: mods) else {
            let l10n = L10n(language: settingsStore.settings.language)
            model.hotkeyRejectMessage = mods == 0 ? l10n.hotkeyRejectTyping : l10n.hotkeyRejectTaken
            return
        }
        if target == .show {
            settingsStore.settings.showHotkeyKeyCode = code
            settingsStore.settings.showHotkeyModifiers = mods
        } else {
            settingsStore.settings.hideHotkeyKeyCode = code
            settingsStore.settings.hideHotkeyModifiers = mods
        }
        model.recordingHotkey = nil
        model.hotkeyRejectMessage = nil
    }

    // MARK: - 键盘：Esc 分层退出 + ⌘. 开合配置面板

    /// Esc 和 ⌘. 都在这里拦。⌘. 不能用 SwiftUI 的 onKeyPress——已实测确认带 command 的
    /// 组合键会被 AppKit 的 key-equivalent 通道消化掉，压根到不了 onKeyPress；
    /// 而这条 NSEvent 本地监听在这个 App 里给 Esc 用了很久，是验证过能用的路径。
    /// 状态栏菜单的 keyEquivalent 也不行：菜单不在主菜单栏里时，它的快捷键不参与全局分发。
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // 输入法组合态探测：SwiftUI 的 binding 在拼音上屏前一直为空，自绘
            // placeholder 靠 inputText.isEmpty 判断会在组合期间残留。field editor 的
            // hasMarkedText 才是真实内容——每次按键刷新一次（组合开始/上屏/取消都覆盖）
            let responder = NSApp.keyWindow?.firstResponder ?? self.windows.first?.firstResponder
            if let fieldEditor = responder as? NSTextView {
                self.model.isComposing = fieldEditor.hasMarkedText()
            } else {
                self.model.isComposing = false
            }
            // 首启引导卡：只有两个键——回车=开始使用（留在覆盖层）、Esc=退出（并收起）。
            // 其他键全吃掉，防误操作；F10 走全局热键那条路（hide 也会标记 seen）
            if self.model.showOnboarding {
                if event.keyCode == 36 { // Return
                    self.dismissOnboarding(hide: false)
                    return nil
                }
                if event.keyCode == 53 { // Esc
                    self.dismissOnboarding(hide: true)
                    return nil
                }
                return nil
            }
            // 热键录制模式：面板里点了「录制」后，下一个键就是新热键（Esc 取消）
            if self.model.recordingHotkey != nil {
                self.handleHotkeyRecording(event)
                return nil
            }
            if event.keyCode == 53 { // Esc
                self.handleEscape()
                return nil
            }
            // Tab（48）：Shift+Tab = 退回顶层输入；Tab = 挂靠子目标。
            // 之前挂在 SwiftUI onKeyPress 上——Tab 能到，但 Shift+Tab 会被 AppKit 的
            // 焦点循环先吃掉（实测用户按 Shift+Tab 没反应，Esc 反而生效）。
            // 本地监听在 AppKit 之前看到所有键，和 Esc 是同一条已验证的路径。
            // 签到卡片开着时放行（Tab 聚焦反馈输入框）；配置面板开着时放行（表单跳字段）
            if event.keyCode == 48 {
                if self.model.pendingCheckInID != nil || self.model.showSettings { return event }
                self.overlayView?.handleTabRequest(shift: event.modifierFlags.contains(.shift))
                return nil
            }
            // 回车（36）：签到卡开着时——纯回车 = 保存反馈并结束；⌘+回车 = 换行
            //（标准键位表里 ⌘+Return 没有绑定，直接往 field editor 插新行）。
            // 输入法组合态下回车归输入法（上屏拼音），不提交
            if event.keyCode == 36, let pending = self.model.pendingCheckInID {
                if event.modifierFlags.contains(.command) {
                    guard !self.model.isComposing else { return event }
                    if let fe = NSApp.keyWindow?.firstResponder as? NSTextView {
                        fe.insertNewline(nil)
                    }
                    return nil
                }
                if !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                    || self.model.isComposing {
                    return event
                }
                self.overlayView?.resolveCheckIn(id: pending, action: .done)
                return nil
            }
            // ⌘+Enter（36）：新建目标并直接按默认时长开始计时，跳过 ⌘T 选择。
            // 编辑中/配置面板开着时放行，让原本的 Return 语义走原路
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                if self.model.showSettings || self.model.editingID != nil {
                    return event
                }
                self.overlayView?.handleInputSubmitArmed()
                return nil
            }
            // ⌘.（keyCode 47 = period）；签到未决时不让它插队
            if event.keyCode == 47, event.modifierFlags.contains(.command),
               self.model.pendingCheckInID == nil {
                self.model.showSettings.toggle()
                return nil
            }
            return event
        }
    }

    private func handleEscape() {
        // 签到未决时 Esc = 继续这个目标并重新选时长——这是设计里的第一动作，
        // 不是「逃跑」。反馈草稿保留，重新选完时长后继续计时
        if model.pendingCheckInID != nil {
            overlayView?.continueCheckInWithTimePick()
            return
        }
        if model.showHistory {
            model.showHistory = false
        } else if model.showSettings {
            model.showSettings = false
        } else if model.isChoosingDuration {
            // 时长选择中 Esc = 取消（⌘T 的小横条、或全屏重选时长都算）；目标已按原时长继续
            model.isChoosingDuration = false
            model.armingTargetID = nil
            model.retimingGoalID = nil
            overlayView?.returnFocusToInput()
        } else if model.selectedID != nil || model.inputParentID != nil {
            model.selectedID = nil
            model.inputParentID = nil
        } else if model.editingID != nil {
            model.editingID = nil
        } else if !model.inputText.isEmpty {
            model.inputText = ""
        } else {
            hide()
        }
    }

    // MARK: - 倒计时签到：周期扫描到期目标

    /// 5s 扫一遍，不给每个目标挂 scheduledTimer——那种在系统睡眠时不会触发，
    /// 醒来后的补偿行为也不可靠。轮询靠的是墙钟比较（now vs firesAt），
    /// 不管睡了多久，醒来后随便哪一次 tick 都能正确判断「已经过期」。
    private func startCheckInScanning() {
        checkInScanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            // Timer 的 block 类型没有 actor 标注，但这个计时器是从 MainActor 上下文
            // 挂到主 run loop 的，触发时确实在主线程——和 hide() 里的动画完成回调一样的情况
            MainActor.assumeIsolated { self?.scanForExpiredTimers() }
        }
    }

    private func scanForExpiredTimers() {
        // 一次只处理一条；处理完的下一次 tick（≤5s）会捡下一条排队的。
        // 全屏重选时长开着时也不弹新卡——用户正对着那个界面，别叠卡。
        // 透明模式下完全不弹——AI 正在操作电脑，签到卡会打断它的截图
        guard model.pendingCheckInID == nil, model.retimingGoalID == nil,
              !settingsStore.settings.transparentMode else { return }
        let now = Date()
        let overdue = store.goals.filter { !$0.isDone && ($0.timer?.firesAt ?? .distantFuture) <= now }
        guard let next = overdue.min(by: { ($0.timer?.firesAt ?? .distantFuture) < ($1.timer?.firesAt ?? .distantFuture) })
        else { return }

        if store.activeCanvasID != next.canvasID {
            store.activeCanvasID = next.canvasID
            store.save()
        }
        // 到期时如果正在编辑，先落盘，不吞掉没保存的修改
        if let editing = model.editingID {
            store.update(id: editing, text: model.editText)
            model.editingID = nil
        }
        model.pendingCheckInID = next.id
        show()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Mirrage")
        }
        statusItem = item
        rebuildMenu()
    }

    /// 菜单文案跟语言走：语言切换时整份重建（item.menu 直接换新）
    private func rebuildMenu() {
        guard let item = statusItem else { return }
        let l10n = L10n(language: settingsStore.settings.language)
        let menu = NSMenu()

        let toggle = NSMenuItem(title: l10n.menuToggle, action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 菜单里也留一条路：⌘. 只在覆盖层可见时管用，而且不是所有人都会去猜有这个快捷键。
        // 从菜单点进来时如果覆盖层还没开，先呼出再开面板。
        let settings = NSMenuItem(title: l10n.menuSettings, action: #selector(settingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        // 透明模式：AI 协作开关（勾选状态实时反映）
        let transparent = NSMenuItem(title: l10n.transparentMode, action: #selector(toggleTransparentMode), keyEquivalent: "")
        transparent.target = self
        transparent.state = settingsStore.settings.transparentMode ? .on : .off
        menu.addItem(transparent)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: l10n.menuQuit, action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func toggleFromMenu() { isVisible ? hide() : show() }

    /// 透明模式：开着时覆盖层对 AI 完全隐形（截图看不见、点击穿透、不弹签到），
    /// 物理屏上人照常看得见。菜单栏和设置面板共用这一个入口
    @objc private func toggleTransparentMode() {
        settingsStore.settings.transparentMode.toggle()
        applyTransparentMode()
    }

    /// 透明模式落地到窗口：sharingType 始终按 transparentMode（截图/录屏永远看不见
    /// 覆盖层——面板开着也一样，AI 不该看到面板）；点击穿透单独算（见 applyWindowClickThrough）。
    /// 开启时清掉待处理的签到——否则卡片还在、下一次扫描还会把它弹回来
    private func applyTransparentMode() {
        let on = settingsStore.settings.transparentMode
        for window in windows {
            window.sharingType = on ? .none : .readOnly
        }
        applyWindowClickThrough()
        if on { model.pendingCheckInID = nil }
    }

    /// 点击穿透只在「透明模式开着 且 没有全屏接管界面」时生效——
    /// 设置面板/历史/签到卡/重选时长都在覆盖层窗口里，穿透开着它们就点不了了
    private func applyWindowClickThrough() {
        let passThrough = settingsStore.settings.transparentMode
            && !modalFlags.settings && !modalFlags.history
            && !modalFlags.checkIn && !modalFlags.retime
        for window in windows {
            window.ignoresMouseEvents = passThrough
        }
    }

    @objc private func settingsFromMenu() {
        if !isVisible { show() }
        model.showSettings = true
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
