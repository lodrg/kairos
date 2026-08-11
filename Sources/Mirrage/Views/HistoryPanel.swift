import SwiftUI

/// 设置里的「历史」子面板：查看曾经完成的目标和签到反馈。
/// 数据直接从 GoalStore 读（goals.json），跟主列表同一份，不是复制。
struct HistoryPanel: View {
    @ObservedObject var store: GoalStore
    let l10n: L10n
    let onClose: () -> Void

    /// 已完成的按完成时间倒序（最新的在最上面）
    private var completedGoals: [Goal] {
        store.goals
            .filter(\.isDone)
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(l10n.historyTitle)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Button(action: onClose) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                            Text(l10n.back)
                        }
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(showsIndicators: false) {
                    if completedGoals.isEmpty {
                        Text(l10n.historyEmpty)
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 80)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(completedGoals) { goal in
                                row(goal)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(30)
            .frame(width: 660, height: 580)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
            .onTapGesture {}
        }
    }

    private func row(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(goal.text)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(spanString(goal))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize()
            }
            if let feedback = goal.feedback, !feedback.isEmpty {
                Text("💬 \(feedback)")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.accent.opacity(0.9))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
    }

    /// 开始 → 结束：同一天只显示时分；跨天带上日期
    private func spanString(_ goal: Goal) -> String {
        let start = goal.startedAt ?? goal.createdAt
        guard let end = goal.completedAt else { return HistoryPanel.startFormatter.string(from: start) }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(HistoryPanel.timeFormatter.string(from: start)) → \(HistoryPanel.timeFormatter.string(from: end))"
        }
        return "\(HistoryPanel.shortFormatter.string(from: start)) → \(HistoryPanel.timeFormatter.string(from: end))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let startFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
