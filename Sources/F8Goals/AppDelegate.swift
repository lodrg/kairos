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

        HotkeyManager.shared.onPress = { [weak self] in
            self?.handleHotkey()
        }
        HotkeyManager.shared.register()

        // 语言切换后菜单栏菜单（AppKit 的）不会自动重绘，这里订阅重建
        languageCancellable = settingsStore.$settings
            .map(\.language)
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildMenu() }
            }

        // 调试入口：F8Goals --show / --hide / --show-settings / --show-arming
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
            let content = OverlayView(store: store, model: model, settingsStore: settingsStore)
            if overlayView == nil { overlayView = content }
            window.contentView = NSHostingView(rootView: content)
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
                for window in self.windows { window.orderOut(nil) }
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

    private func handleHotkey() {
        if isVisible {
            hide() // 可见时，单击 F10 即收起
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastPress) < doubleTapInterval {
            lastPress = .distantPast
            show() // 双击 F10 呼出
        } else {
            lastPress = now
        }
    }

    // MARK: - 键盘：Esc 分层退出 + ⌘. 开合配置面板

    /// Esc 和 ⌘. 都在这里拦。⌘. 不能用 SwiftUI 的 onKeyPress——已实测确认带 command 的
    /// 组合键会被 AppKit 的 key-equivalent 通道消化掉，压根到不了 onKeyPress；
    /// 而这条 NSEvent 本地监听在这个 App 里给 Esc 用了很久，是验证过能用的路径。
    /// 状态栏菜单的 keyEquivalent 也不行：菜单不在主菜单栏里时，它的快捷键不参与全局分发。
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
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
            // ⌘+Enter（36）：新建目标并直接按默认时长武装，跳过 ⌘T 选择。
            // 编辑中/签到卡片/配置面板开着时放行，让原本的 Return 语义走原路
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                if self.model.pendingCheckInID != nil || self.model.showSettings || self.model.editingID != nil {
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
        // 全屏重选时长开着时也不弹新卡——用户正对着那个界面，别叠卡
        guard model.pendingCheckInID == nil, model.retimingGoalID == nil else { return }
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
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "F8Goals")
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

        menu.addItem(.separator())
        let quit = NSMenuItem(title: l10n.menuQuit, action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func toggleFromMenu() { isVisible ? hide() : show() }

    @objc private func settingsFromMenu() {
        if !isVisible { show() }
        model.showSettings = true
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
