import AppKit
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
    private var windows: [NSWindow] = []
    private var statusItem: NSStatusItem?

    private var isVisible = false
    private var lastPress = Date.distantPast
    /// 双击判定窗口：双击 F10 呼出；可见时单击 F10 或 Esc 收起
    private let doubleTapInterval: TimeInterval = 0.45

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindows()
        setupStatusItem()
        installEscapeMonitor()

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

        // 调试入口：F8Goals --show / --hide
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.show() }
        } else if CommandLine.arguments.contains("--hide") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hide() }
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
            window.contentView = NSHostingView(rootView: OverlayView(store: store, model: model))
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
        NSApp.activate()
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
    func hide() {
        guard isVisible else { return }
        isVisible = false

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

    // MARK: - Esc：先退出选中/子目标态 → 取消编辑 → 清空草稿 → 收起

    private func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 只在覆盖层可见时拦 Esc。原来无条件吞掉，导致 App 处于活跃态
            // （比如菜单栏菜单打开时）Esc 也被吃掉
            guard let self, self.isVisible, event.keyCode == 53 else { return event }
            self.handleEscape()
            return nil
        }
    }

    private func handleEscape() {
        if model.selectedID != nil || model.inputParentID != nil {
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

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "F8Goals")
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show / Hide  (double-tap F10)", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit F8Goals", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFromMenu() { isVisible ? hide() : show() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
