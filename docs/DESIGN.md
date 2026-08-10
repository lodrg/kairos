# Mirrage 工程设计文档

用户向的 README 之外的工程决策记录：布局与动效、逐条设计要点、踩过的坑。
和 README 一样随代码演进——改了实现就改这里。

## 布局与动效

动效一律只用淡入淡出，不做位移、缩放、模糊、错峰。

- **输入栏位置**：目标少时停在屏幕高度 58% 处（略低于正中，视觉重心更稳；配置面板
  Input bar position 可调 35%-75%）；目标堆到要越过屏幕上缘时，列表区继续往下长、
  输入栏跟着下沉；沉到离屏幕底部还剩 56pt 就停住。
- **位置变化一律慢慢挪**：输入栏下沉/回升、某条目标消失后其余目标移位，共用
  `Motion.layout`（0.55s easeInOut），比内容淡入淡出慢一截。
- **装不下时**：只渲染放得下的最后若干条，更早的从顶部渐隐消失（遮罩渐变，不是硬切）。
  遮罩只在真的装不下时才挂——`mask` 会把内容裁到遮罩自身范围内，不需要渐隐就别裁，
  否则动画途中还没走到位的行会被切掉顶部的文字。区域高度恒 ≥ 行总高，保证行不被裁
  （已用脚本验证 Text size 75%-135% 全范围、不同目标数下成立）。
- **高度不靠测量**：区域高度 = 每行各自高度累加，全部算出来，不测量任何子视图。
  子目标行更矮，所以是累加不是「行数 × 单一行高」。
- **呼出**：窗口淡入 0.34s，内容同步淡入，共用 `Motion.Duration.reveal`。
- **收起**：窗口淡出 0.26s；等透明之后才复位内容状态，避免内容一边缩一边淡的拖沓感。
- **勾选**：整行淡出 0.55s 后从列表让位（JSON 保留记录），输入栏随之慢慢回升。
- **背景**：`MeshGradient` 九个控制点被慢速正弦扰动（幅度 16%-22%），配色提亮过的
  蓝/紫/青色板。**10fps**（漂移/呼吸全是慢变化，15fps 是 2-4 倍冗余）；覆盖层不可见时
  `TimelineView` 暂停。实测 CPU：可见约 0.4-7%（显示器睡眠会限流渲染路径，数字波动大），
  隐藏 0.0%。
- **呼吸**：辉光透明度沿 7s 正弦在 **0↔0.55** 明灭 + 全屏变暗层 **0.05↔0.45** 同相起伏
  （辉光亮时背景最亮、灭时最暗），整屏一明一灭。复用同一个 `TimelineView` 时钟。
  历史上呼吸效果三度「看不见」：摆幅 0.030↔0.060（差 3% 无感）→ 0↔0.26（局部辉光
  在暗背景下仍难辨）→ 最终 0↔0.55 + 全屏变暗层。**还踩过一个结构坑**：呼吸层曾藏在
  「极光开关」分支里，极光一关整个 TimelineView 都不启动，呼吸开关形同虚设——
  后来合并成单一「动态背景」开关，两个效果一体开关。

## 设计要点

- **全局热键**：Carbon `RegisterEventHotKey(kVK_F10)`，无需辅助功能/输入监控权限。
- **覆盖层**：无边框窗口 + `.screenSaver` 层级 + 跨 Space，遮住菜单栏与所有应用，
  不打断底层 App。多屏每屏一块窗口，监听 `didChangeScreenParametersNotification`
  在接/拔显示器后重建。
- **动效单一来源**：所有曲线和时长集中在 `Theme.swift` 的 `Motion`，SwiftUI 与 AppKit
  共用同一组时长——窗口淡入淡出和内容动画才不会是两个时钟。
- **不测量布局**：行高、输入栏高度是常量，区域高度由行数算出。之前用 `GeometryReader`
  量出高度再回填 `@State`，形成「内容高度 → 布局 → 内容高度」的回路，是画面抖动的根源。
- **入场纯推导**：行的透明度只由 `revealed` 推导，行内不存动画状态，每次呼出都能正确重播。
- **行位置显式定位**：行不靠 `VStack` 自然重排，而是 `ZStack` + `offset(y: -到底部的累加高度)`。
  交给 VStack 重排的话，位置变化没有可绑定的值，只能依赖外层 `withAnimation` 的环境事务，
  而行自己的 `.animation(_:value:)` 会把环境动画挡掉——结果就是某条目标消失后其余目标
  瞬间跳位。显式定位后这个偏移量（CGFloat）本身成了可动画的值（v1.1 用 `Int` 的
  indexFromBottom 是同一个技巧，只是泛化成累加不等高的行）。
- **完成状态单一来源**：`completingIDs` / `retiredIDs` 两个集合 + `Motion.completion`
  一个时长常量，收起时清空；不靠 `Date()` 在计算属性里比时间。
- **方向键有条件拦截**：`onKeyPress` 挂在覆盖层最外层（离实际聚焦的 TextField 很远），
  靠返回 `.ignored` 放行给输入框、`.handled` 消费掉。这依赖一个没有官方文档明确保证的
  行为——TextField 聚焦且有内容时，方向键是否还会冒泡到远处的祖先 `onKeyPress`——
  已用独立的最小 SwiftUI harness 实测确认会冒泡才照此实现。
- **画布切不做横向滑动**：用 `.id(activeCanvasID)` 强制整块目标区换身份，配合
  `.transition(.asymmetric(...))` 做交叉淡入 + 顺方向位移；比真正的滑动便宜，
  也不需要所有画布同时留在视图树里。
- **组合键必须走本地监听**：⌘.、⌘+Enter、Esc、Tab、Shift+Tab、签到键全部在
  AppDelegate 的 `NSEvent` 本地监听里拦（在 AppKit 之前看到所有键）。两个实测坑：
  1. 带 command 的组合键被 AppKit 的 key-equivalent 通道吃掉，`onKeyPress` 一次都不触发；
  2. Shift+Tab 被 AppKit 焦点循环（key view loop）先吃掉，`onKeyPress` 只收得到 Tab。
  状态栏菜单的 `keyEquivalent` 也不行：菜单不在主菜单栏里时快捷键不参与全局分发。
- **Tab 必须吃掉不能放行**：放行会掉进 AppKit 焦点循环，把光标从输入框抢到旁边的
  表盘按钮上——既打不了字、按空格还会误触计时器。已实测：Button 默认可聚焦 +
  返回 `.ignored`，Tab 之后 firstResponder 变成 KeyViewProxy 而不是输入框。
- **选中/子目标状态在收起、切画布时清空**：`selectedID` / `inputParentID` 是纯 UI 态，
  不落盘；收起时随 `resetTransient()` 一起清，切画布时单独清（否则残留一个指向别的
  画布目标的挂靠对象）。
- **挂靠状态 ↑/↓ = 移动挂靠对象**：挂靠中（输入子目标）不再产生独立选中态——上下键
  直接在顶层目标间切换挂靠对象，父目标高亮跟着走。避免「父目标高亮 + 选中条 + 回车
  误勾掉别的目标」的三重混乱。
- **勾掉目标后光标挤到上一条**：完成的目标要淡出退休，光标停在它身上会凭空消失；
  挤到上一条（它在行位移中原地不动，光标不跳），没有上一条才用下一条。
- **签到未决时其余按键全部让路**：方向键、Tab、⌘T、⌘. 的 guard 里都有
  `pendingCheckInID == nil`；`hide()` 自己也拒绝执行（F10 / 菜单栏都走这一个函数，
  挡在这一处比每个调用点各自判断更不容易漏）。`pendingCheckInID` 故意不放进
  `resetTransient()`，否则收起动画走完时会把还没处理的签到悄悄清掉。
- **签到卡片只有两个键**：Enter = 保存反馈并结束（走卡片输入框的 `onSubmit`），
  Esc = 继续 + 全屏重选时长（走本地监听 `continueCheckInWithTimePick`）。
  反馈输入框自动聚焦——没有快捷键需要让位，字母数字全是输入，不存在冲突。
  早期版本是 D/K/S/X + 1-4 四动作（End/Keep going/Snooze/Drop），用户要求砍掉：
  快捷键和输入打架的复杂度不值得。
- **全屏重选时长独立于 ⌘T 的小横条**：`retimingGoalID` 非 nil 时显示全屏时长选择
  （大块预设 + 自定义输入），Esc 继续专用；⌘T 武装新目标仍走输入栏底部小横条。
  两者共用 `isChoosingDuration` / `draftMinutesIndex` / `durationOptions` 的键位与确认逻辑。
  全屏选择默认落在 **3 分钟**（用户指定：最快的继续路径）。到期扫描在重选时长开着时
  不弹新卡（`retimingGoalID == nil` 加进 guard），避免叠卡。
- **确认时长不靠拦截 Return**：选时长时第一次回车是「确认时长」、第二次才是「建目标」，
  靠 TextField 自带的 `onSubmit` 回调自己判断 `isChoosingDuration`，不是用 `onKeyPress`
  抢在 `onSubmit` 前面拦 Return——两者先后顺序文档没保证，干脆不依赖。
- **⌘+Enter = 创建 + 默认时长武装**：直接 `store.add(text, parentID:, minutes: defaultMinutes)`，
  跳过选择。挂在本地监听（keyCode 36 + command），编辑中/签到/设置面板开着时放行。
- **到期扫描用轮询比墙钟，不用 per-goal 的系统定时器**：后者在 Mac 睡眠时不触发，
  醒来后的补偿行为也不可靠；轮询只要「醒着的时候总会再 tick 一次」就能判断对错，
  跟睡了多久无关。已端到端实测：注入一条已过期的计时器、冷启动（不带调试参数），
  等一次 tick 后覆盖层自动弹出、且正确切到了目标所在的画布。
- **配置改动即时生效，不用重启**：`SettingsStore.settings` 的 `didSet` 直接 `save()`，
  面板控件基本都直接绑定 `$settingsStore.settings.某字段`——改一下、存一下、
  界面上该反映的地方立刻反映，没有「应用」按钮。
- **动态背景关闭是真的不起动画**：`AuroraBackground` 的 `animated=false` 分支整个跳过
  `TimelineView`，换成静态 `LinearGradient`；实测这种状态下 CPU 0.0%（覆盖层可见时），
  跟「隐藏覆盖层」的零耗一个量级，而不是仍在后台画只是看不出来。
- **尺寸可配置走参数传递，不走 SwiftUI environment**：`LayoutMetrics` 由
  `Settings.textScale` / `inputRestingFraction` 解析出来，作为普通参数一路传给
  `GoalRow`、`trimToFit`、行位置计算——不塞进 `.environment(\.xxx)` 全局广播。
  这个 App 每块屏幕单独一个 `NSHostingView`，环境值跨窗口传递的边界情况没有验证过，
  显式参数是这个代码库从第一天就在用的风格，风险更小。`Metrics.contentWidth` 故意
  不参与缩放——缩放管竖直方向的行高字号，跟横向排版是两件事。默认值（scale=1.0,
  restingFraction=0.58）已用脚本核对过和重构前的硬编码常量逐项数值相等。
- **常驻内存最小化（图层树随显隐走）**：全屏窗口的 CALayer/IOSurface 后备存储约 33MB
  ——覆盖层**隐藏时 `window.contentView = nil` 整棵释放**（连同 overlayView 引用），
  呼出时 `show()` 懒重建；`buildWindows()` 启动时也不挂 contentView。
  实测物理占用：启动即隐藏 **12.4MB**、可见 **106MB**、收起回落 **28MB**；
  5 轮 show/hide 循环 25.3-25.7MB 稳定，无泄漏。
  **坑**：`window.contentView` 的 getter 会**惰性自动创建空 NSView**，永远不为 nil——
  判断"是否已构建"必须用 `is NSHostingView<OverlayView>`，直接判 nil 会永远跳过挂载
  （实测：覆盖层变成隐形空窗）。
- **settings.json 解码全字段兜底**：旧版文件缺字段（如 language）时直接走合成解码会
  整个 decode 失败、用户全部配置被静默重置。所有字段 `decodeIfPresent` 兜底。
  键位迁移也在这里做：合并成「动态背景」单开关后，CodingKeys 显式保留旧键
  `auroraEnabled` 仅供迁移解码，手写 `encode(to:)` 只写现有字段（合成 encode 会因
  无属性对应的键失败）。
- **无 Dock 图标后台常驻**：`LSUIElement`；菜单栏是唯一的常驻界面，窗口按需创建。
- 技术栈：SwiftUI 内容 + AppKit 窗口壳，SwiftPM 可执行目标，macOS 15+。

## 验证方法论（踩过的坑）

- 显示器会休眠/锁屏：全屏截图会拿到锁屏壁纸/全黑。验证动画必须
  `caffeinate -u -d -t N sh -c '...'` 包裹，窗口级抓取
  `screencapture -l$(swift /tmp/winid.swift | awk '{print $1}')` 时灵时不灵，需循环重试。
- 自动化发键会污染前台聊天应用（WeChat/Hermes 前台时禁发键）；按键类验证留给用户。
- 测试数据注入：goals.json 的 `Date` 由 JSONDecoder 按 **2001 基准**
  （timeIntervalSinceReferenceDate）解码，注入用 `REF = 978307200`；`firesAt` 是
  计算属性不可注入，注入 `startedAt` + `minutes`。
- 该 App 的 NSLog 不进 unified log——诊断用文件日志（/tmp）。
- 调试参数（`--show` / `--show-settings` / `--show-arming` / `--show-retime <ID>`）
  是给「只能用键盘到达的状态」留的确定性入口：远程或没有辅助功能权限时，
  没法真的按键，只能靠启动参数把状态摆出来看一眼。
