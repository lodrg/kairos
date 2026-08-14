# Kairos（时机）工程设计文档

用户向的 README 之外的工程决策记录：布局与动效、逐条设计要点、踩过的坑。
和 README 一样随代码演进——改了实现就改这里。

## 布局与动效

动效一律只用淡入淡出，不做位移、缩放、模糊、错峰。

### 黄金比例体系（φ = 1.618）

整套尺寸围绕黄金比派生，且**基线固定**——任意列表高度下构图都保持黄金分割：

- **输入栏中线 = 屏幕高 ÷ φ ≈ 0.618**：输入栏以上 61.8% 是目标生长区、以下 38.2% 是
  操作区。中线位置固定不随内容漂移（配置面板可调 35%-75%，默认 0.618）。
- **行高 = 字高 × φ**：目标行 46pt × φ ≈ 74。
- **输入栏高 : 行高 ≈ φ**：122 ÷ 74 = 1.649 ≈ 1.618（数值自然落位）。
- **呼出 : 收起时长 = φ**：0.34 ÷ 0.21 = 1.618——慢进快出，收得比出利落。

### 布局行为

- **输入栏位置**：目标少时停在屏幕高度 61.8%（黄金分割位，视觉重心稳；配置面板
  Input bar position 可调 35%-75%）；目标堆到要越过屏幕上缘时，列表区继续往下长、
  输入栏跟着下沉；沉到离屏幕底部还剩 56pt 就停住。
- **位置变化一律慢慢挪**：输入栏下沉/回升、某条目标消失后其余目标移位，共用
  `Motion.layout`（0.55s easeInOut），比内容淡入淡出慢一截。
- **装不下时**：只渲染放得下的最后若干条，更早的从顶部渐隐消失（遮罩渐变，不是硬切）。
  遮罩只在真的装不下时才挂——`mask` 会把内容裁到遮罩自身范围内，不需要渐隐就别裁，
  否则动画途中还没走到位的行会被切掉顶部的文字。区域高度恒 ≥ 行总高，保证行不被裁
  （已用脚本验证 Text size 75%-135% 全范围、不同目标数下成立）。
- **高度不靠测量**：区域高度 = 行高常量 × 行数，全部算出来，不测量任何子视图。
  （旧版有子目标时行高不等，得逐行累加；扁平化后就是一行等高的乘法。）
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

- **全局热键**：Carbon `RegisterEventHotKey`，无需辅助功能/输入监控权限。
  **只有一个呼出键**（默认 **⌘⇧S**，可录制），**开关式**——隐藏按一下呼出、可见按一下
  收起（呼出后 0.45s 内的再次按下视为旧版「双击呼出」肌肉记忆残留，忽略不收起），
  Esc 兜底收起——旧版「呼出键 + 收起键、相同时双击呼出/单击收起」的复杂度里，
  收起键和 Esc 职责重复，砍掉后语义更干净（曾做成「可见时按呼出键 = 无操作」，
  用户实测反馈「录了 F10 没反应」，其实是覆盖层已经开着按了没动静——改成开关式）。
  默认值先后试过裸 F10 和 ⌃⌥F10，最后定 ⌘⇧S：**不是 F 键**，不依赖「标准功能键」
  设置（系统默认 F 键是媒体键，F10=静音，按键到不了 App），带修饰键的组合也极少被
  全局占用。
  **冲突检测**：`RegisterEventHotKey` 返回 `eventHotKeyExistsErr`（-9878）说明键被别的
  App 全局占用——不再静默 NSLog，而是记进 `failedKeys` 摆到设置面板红字 + 首启引导卡上。
  但实测发现 **macOS 对跨 App 相同组合不强制互斥**（两个进程都能注册成功），冲突检测
  只能兜底；真正会让「录了没反应」的是 F 键被系统当媒体键（`com.apple.keyboard.fnState`
  = 0，默认值）——按键到不了 App。对策：录制时读到裸 F 键 + fnState=0 当场拒绝并指路，
  设置面板对当前裸 F 键热键常驻红字提示。
  键名显示补全 ANSI 字母/数字/符号的 kVK 映射——旧版只有 F 键和特殊键，录 ⌘S 会
  显示成「⌘1」。
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
- **组合键必须走本地监听**：⌘.、⌘+Enter、⌘+Backspace、退格删编辑目标、Esc、签到键
  全部在 AppDelegate 的 `NSEvent` 本地监听里拦（在 AppKit 之前看到所有键）。
  实测坑：带 command 的组合键被 AppKit 的 key-equivalent 通道吃掉，`onKeyPress`
  一次都不触发；状态栏菜单的 `keyEquivalent` 也不行——菜单不在主菜单栏里时快捷键
  不参与全局分发。
- **选中态在收起、切画布时清空**：`selectedID` 是纯 UI 态，不落盘；收起时随
  `resetTransient()` 一起清，切画布时单独清（否则残留一个指向别的画布目标的选中）。
- **勾掉目标后光标挤到上一条**：完成的目标要淡出退休，光标停在它身上会凭空消失；
  挤到上一条（它在行位移中原地不动，光标不跳），没有上一条才用下一条。
  删除目标复用同一套落点逻辑。
- **删除 = 淡出 + 可反悔，纯键盘**：删除是低频操作，不配常驻按钮（悬停垃圾桶已按
  用户要求移除）。三个入口同一套退场：编辑中清空文本后按**退格**（退格在空输入框里
  本来就是无操作，拦下来零副作用；带修饰键的退格和输入法组合态放行）、编辑清空 +
  回车（保留旧语义）、选中 + ⌘+Backspace（Finder 式肌肉记忆）。目标进 `deletingIDs`
  用 `Motion.retire` 淡出，0.55s 后 Task 才真正调 `store.delete`——淡出中点击该行
  （`cancelDelete`）或按 Esc 收起（`resetTransient` 清空 `deletingIDs`，Task 守卫失败）
  都能反悔。删除与完成共用 `completingIDs` 会打架（反悔语义不同），所以删除单独用
  一套 `deletingIDs`，两边的 `complete`/`deleteGoal` 互相 guard。
- **砍掉二级（子目标）结构**：旧版的两层子目标（Tab 挂靠 / Shift+Tab 提升 / 父高亮 /
  删父级联）整体移除——`Goal` 的 `parentID` 字段、`GoalStore.promote`、
  `normalizeDepth`、`inputParentID` 挂靠态、缩进布局全部删除。旧 goals.json 里的
  `parentID` 键被解码器自动忽略，历史子目标自然摊平成顶层目标，无需迁移代码。
  扁平化后行高统一（`Metrics.subRowHeight` 等全部删除），Tab 键回归系统默认行为。
- **删掉旧版「关闭签到」开关**：`checkInEscDismisses`（旧语义「F10 直接关签到卡」）
  依赖「呼出键兼任收起键」的旧热键模型——呼出键不再承担收起后这个开关失去载体，
  整个移除。签到只有两个出口：回车=结束、Esc=继续，强制签到名副其实（菜单栏收起
  也被 `hide()` 的 `pendingCheckInID == nil` 挡住）。旧 settings.json 里的该键由
  JSONDecoder 自动忽略，不影响迁移。
- **配置面板高度自适应**：面板不再固定 520pt 高竖排。`ViewThatFits(in: .vertical)`
  两个分支——屏幕放得下就用自然高度 VStack（零改动），放不下自动落第二个分支：
  同一份内容包进 ScrollView、高度封顶屏幕 86%、宽度跟着屏幕收窄。画布列表原有的
  内层滚动保留（大屏时只它滚动，不整页滚）。历史面板同样改成宽高跟随屏幕。
  坑：SwiftUI 没有 `frame(width:maxHeight:)` 这个重载，链两个 frame 在 ZStack 里会
  互相抢提案，ScrollView 直接用固定 height 才可靠。
- **背景 HSV 三项可调 = 纯颜色修饰**：`backgroundHue`（0–360°）、`backgroundSaturation`
  （0–2）、`backgroundBrightness`（0–2），默认值分别为 0 / 1.0 / 1.0（保持现状）。
  全部在**调色板源头**做（`Color.adjustingHSV`：NSColor 取色相/饱和度/明度 → 色相平移、
  饱和度/明度缩放、钳制 → 转回），不是 `.saturation()`/`.brightness()` 那种逐像素整体
  变换（会洗淡/发闷）。渲染、MeshGradient 扰动、呼吸、暗角、噪点、画布 hueShift（在
  OverlayView 单独叠加）任何一层逻辑都不动，也不碰布局/动效。设置面板里背景独立成卡：
  动态背景开关 + 三个滑杆（连续调色比步进器顺手），外观与布局卡只留透明模式 + 布局
  步进器。旧 settings.json 里的 backgroundSaturation/backgroundBrightness 键直接沿用，
  范围放宽后旧值仍然有效。
- **长文本与多行编辑**：目标显示 `lineLimit(2)` + `minimumScaleFactor(0.55)`——
  一行放不下先换行、再整体缩字号，仍放不下才省略号；完整内容点进去编辑可见。
  编辑按内容长度切两种输入器：短文本（≤18 字符、无换行）用单行 TextField（回车保存，
  行高不变）；长/多行自动换 TextEditor（多行编辑行临时加高到 `editRowHeight`，其余行
  不变）。多行编辑的键位与签到反馈同一套：**纯回车 = 保存、⌘+回车 = 换行**——在本地
  监听里拦截（TextEditor 原生回车是换行，必须抢在它前面）。布局引擎按每行高度累加
  （`OverlayView.rowHeight(for:sizing:)`），编辑行加高不会破坏"不测量"原则——行高是
  确定性规则（看编辑内容长度），不是 GeometryReader 量出来的。新建输入栏保持单行：
  「打字 + 回车 = 创建」是核心交互，多行长内容走编辑路径。
- **多行粘贴 = 批量创建**：输入栏聚焦 + 剪贴板含多行 + 输入框为空时，⌘+V 被本地监听
  拦下（keyCode 9 + command），按行切分、逐条 `store.add`——从任何 App 复制一段待办
  清单粘贴即捕获，一次建 N 条。三个 guard：输入框非空放行（打字到一半粘贴不该丢字）、
  编辑/签到/设置/重选时长里放行（那些输入框原生支持多行粘贴）、输入法组合态放行。
  单行粘贴原样走输入框，不受影响。
- **底部计时光带（非唤起态的环境式时间感）**：覆盖层**收起**时，所有画布中最快到期、
  未到期的活跃计时器显示为屏幕底部一条 3pt 消耗光带（`TimerBarView` + `TimerProgressBar`）。
  架构：AppDelegate 每屏建一条常驻浮动窗口（`buildTimerBarWindows`，贴 visibleFrame 底部
  = Dock 上方，`.floating` 层级、`ignoresMouseEvents`、borderless、可跨 Space），内容视图
  观察 GoalStore/OverlayModel——`model.animatedIn` 为真（覆盖层唤起）或没有活跃计时器时
  内容清空，窗口全透明；有计时且收起时才渲染光带（TimelineView 1fps + 线性补间连续消耗，
  剩最后 10% 变暖橙）。窗口只有 16pt 高，常驻不释放图层也几乎不占内存，跟全屏覆盖层的
  「显隐释放」策略分开。透明模式下对 AI 截图隐形（sharingType 跟随）。
- **签到未决时其余按键全部让路**：方向键、⌘T、⌘. 的 guard 里都有
  `pendingCheckInID == nil`；`hide()` 自己也拒绝执行（呼出键 / 菜单栏都走这一个函数，
  挡在这一处比每个调用点各自判断更不容易漏）。`pendingCheckInID` 故意不放进
  `resetTransient()`，否则收起动画走完时会把还没处理的签到悄悄清掉。
- **签到卡片只有两个键**：Enter = 保存反馈并结束（走卡片输入框的 `onSubmit`），
  Esc = 继续 + 全屏重选时长（走本地监听 `continueCheckInWithTimePick`）。
  反馈输入框自动聚焦——没有快捷键需要让位，字母数字全是输入，不存在冲突。
  早期版本是 D/K/S/X + 1-4 四动作（End/Keep going/Snooze/Drop），用户要求砍掉：
  快捷键和输入打架的复杂度不值得。
- **全屏重选时长独立于 ⌘T 的小横条**：`retimingGoalID` 非 nil 时显示全屏时长选择
  （大块预设 + 自定义输入），Esc 继续专用；⌘T 给新目标计时仍走输入栏底部小横条。
  两者共用 `isChoosingDuration` / `draftMinutesIndex` / `durationOptions` 的键位与确认逻辑。
  全屏选择默认落在目标**当前时长**（连续延长时回车即按同样时长继续，用户要求），
  当前时长不在预设里才退回 3 分钟。到期扫描在重选时长开着时
  不弹新卡（`retimingGoalID == nil` 加进 guard），避免叠卡。
- **确认时长不靠拦截 Return**：选时长时第一次回车是「确认时长」、第二次才是「建目标」，
  靠 TextField 自带的 `onSubmit` 回调自己判断 `isChoosingDuration`，不是用 `onKeyPress`
  抢在 `onSubmit` 前面拦 Return——两者先后顺序文档没保证，干脆不依赖。
- **⌘+Enter = 创建 + 默认时长开始计时**：直接 `store.add(text, minutes: defaultMinutes)`，
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
