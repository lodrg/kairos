import AppKit

// 无 Dock 图标的背景常驻 App（accessory），通过全局热键 + 菜单栏操作
// main.swift 顶层代码运行在主线程上，assumeIsolated 是安全的
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
