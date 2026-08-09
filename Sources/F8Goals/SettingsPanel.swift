import SwiftUI

/// ⌘. 呼出的配置面板：盖住目标区，保持现有视觉语言，不开新窗口。
/// 倒计时签到那一段放最前面并做视觉强调——这是本版最重要的配置项。
struct SettingsPanel: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var store: GoalStore
    let onClose: () -> Void

    @State private var presetsText = ""
    @State private var newCanvasName = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case presets, newCanvas }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 36) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    countdownSection
                    canvasSection
                    appearanceSection

                    Text("Esc to close")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.22))
                }
                .padding(48)
            }
            .frame(maxWidth: 620, maxHeight: 780)
            .background(Color.black.opacity(0.001)) // 让整块面板本身也吃点击，不穿透到 scrim
            .onTapGesture {}
        }
        .onAppear {
            presetsText = settingsStore.settings.durationPresetsMinutes.map(String.init).joined(separator: " ")
        }
    }

    // MARK: - 倒计时签到（重点强调）

    private var countdownSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("COUNTDOWN CHECK-IN")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent.opacity(0.9))
                .tracking(1.4)

            settingsRow("Presets (minutes)") {
                TextField("5 15 25 45", text: $presetsText)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
                    .focused($focusedField, equals: .presets)
                    .onSubmit(commitPresets)
            }

            SettingsStepper(
                label: "Default duration",
                value: $settingsStore.settings.defaultMinutes,
                range: 1...180, step: 5, unit: "m"
            )
            SettingsStepper(
                label: "Snooze duration",
                value: $settingsStore.settings.snoozeMinutes,
                range: 1...60, step: 1, unit: "m"
            )
            SettingsToggle(label: "Auto-arm new goals", isOn: $settingsStore.settings.autoArmNewGoals)
            SettingsToggle(label: "Keep armed after creating", isOn: $settingsStore.settings.keepArmedAfterCreate)
            SettingsToggle(label: "Esc / F10 dismiss check-in", isOn: $settingsStore.settings.checkInEscDismisses)
        }
    }

    private func commitPresets() {
        let numbers = presetsText
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Int($0) }
            .filter { $0 > 0 }
        if !numbers.isEmpty {
            settingsStore.settings.durationPresetsMinutes = Array(Set(numbers)).sorted()
        }
        // 解析不出有效数字就还原成当前值，不留一个空列表——那样武装面板就没有可选的时长了
        presetsText = settingsStore.settings.durationPresetsMinutes.map(String.init).joined(separator: " ")
    }

    // MARK: - 画布

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CANVASES")

            ForEach(store.canvases) { canvas in
                CanvasRow(canvas: canvas, canDelete: store.canvases.count > 1, store: store)
            }

            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 16)
                TextField("Add canvas", text: $newCanvasName)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
                    .focused($focusedField, equals: .newCanvas)
                    .onSubmit(addCanvas)
            }
        }
    }

    private func addCanvas() {
        let trimmed = newCanvasName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addCanvas(name: trimmed)
        newCanvasName = ""
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("APPEARANCE")
            SettingsToggle(label: "Breathing background", isOn: $settingsStore.settings.breathingEnabled)
            SettingsToggle(label: "Aurora background", isOn: $settingsStore.settings.auroraEnabled)
        }
    }

    // MARK: - 共用小件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .tracking(1.4)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            content()
        }
    }
}

// MARK: - 画布行：色相选择 + 改名 + 删除

private struct CanvasRow: View {
    let canvas: Canvas
    let canDelete: Bool
    @ObservedObject var store: GoalStore

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(Palette.canvasHues, id: \.self) { hue in
                    Circle()
                        .fill(Color(hue: hue / 360, saturation: 0.55, brightness: 0.85))
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(canvas.hueShift == hue ? 0.85 : 0), lineWidth: 2)
                        }
                        .onTapGesture { store.setCanvasHue(canvas.id, hue: hue) }
                }
            }

            TextField("", text: $name)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .textFieldStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .tint(Palette.accent)
                .focused($focused)
                .onSubmit { store.renameCanvas(canvas.id, to: name) }

            Spacer(minLength: 0)

            if canDelete {
                Button(action: { store.deleteCanvas(canvas.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.28))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { name = canvas.name }
    }
}

// MARK: - 开关：小圆点滑动的胶囊，不是描边框

struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack {
                Text(label)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isOn ? Palette.accent : Color.white.opacity(0.08))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white.opacity(0.92))
                            .frame(width: 16, height: 16)
                            .padding(3)
                    }
            }
        }
        .buttonStyle(.plain)
        .animation(Motion.fade, value: isOn)
    }
}

// MARK: - 数值步进器

struct SettingsStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            HStack(spacing: 14) {
                stepButton("minus") { value = max(range.lowerBound, value - step) }
                Text("\(value)\(unit)")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(minWidth: 44)
                stepButton("plus") { value = min(range.upperBound, value + step) }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
