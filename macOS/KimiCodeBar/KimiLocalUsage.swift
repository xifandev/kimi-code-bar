import SwiftUI

// MARK: - 本地用量数据模型

/// 某一天的本地 Token 消耗（来自 Kimi Code 本地会话记录 wire.jsonl 的 usage.record 事件）
struct LocalUsageDay: Identifiable {
    var id: Date { date }
    let date: Date          // 当天 0 点（本地时区）
    var input: Int = 0      // 输入合计 = 非缓存 + 缓存读 + 缓存写
    var output: Int = 0     // 输出
    var cacheRead: Int = 0  // 缓存读（用于命中率）

    var totalTokens: Int { input + output }
}

/// 用量统计时间范围：累计（默认）/ 今日 / 7天
enum LocalUsageRange: String, CaseIterable, Identifiable {
    case all
    case today
    case week

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return LanguageManager.tr("累计")
        case .today: return LanguageManager.tr("今日")
        case .week: return LanguageManager.tr("7天")
        }
    }
}

// MARK: - 本地用量服务

/// 扫描 Kimi Code 本地会话记录（sessions/<工作目录>/<会话>/agents/*/wire.jsonl），
/// 聚合 usage.record 事件得出按天 Token 消耗。
/// 原则：只读，绝不修改官方任何文件；不触碰 credentials；尊重 KIMI_CODE_HOME。
/// 策略：打开面板时全量扫描一次（实测 362MB 约 1s），不做实时监听；
/// 结果内存缓存 + 3 分钟节流；扫描在后台线程执行，不阻塞 UI。
@MainActor
final class KimiLocalUsageService: ObservableObject {
    static let shared = KimiLocalUsageService()

    @Published private(set) var days: [LocalUsageDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasScanned = false

    private var lastScanDate: Date?
    private let throttleInterval: TimeInterval = 180

    private init() {}

    /// 面板打开时调用；3 分钟内重复打开不重复扫描
    func refreshIfNeeded() {
        guard !isLoading else { return }
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < throttleInterval { return }
        isLoading = true
        Task {
            let scanned = await Task.detached(priority: .utility) {
                Self.scanSessionFiles()
            }.value
            days = scanned
            hasScanned = true
            isLoading = false
            lastScanDate = Date()
        }
    }

    /// 按范围过滤：累计=全部，今日=今天 0 点起，7天=近 7 个自然日（含今天）
    func days(in range: LocalUsageRange) -> [LocalUsageDay] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        switch range {
        case .all:
            return days
        case .today:
            return days.filter { $0.date >= todayStart }
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            return days.filter { $0.date >= start }
        }
    }

    // MARK: 数字格式化（随显示语言：中文 亿/万，英文 B/M/K）

    static func formatTokenCount(_ count: Int) -> (value: String, unit: String) {
        if LanguageManager.resolvedLanguage == .zhHans {
            if count >= 100_000_000 { return (scaled(count, by: 100_000_000), "亿") }
            if count >= 10_000 { return (scaled(count, by: 10_000), "万") }
            return ("\(count)", "")
        }
        if count >= 1_000_000_000 { return (scaled(count, by: 1_000_000_000), "B") }
        if count >= 1_000_000 { return (scaled(count, by: 1_000_000), "M") }
        if count >= 1_000 { return (scaled(count, by: 1_000), "K") }
        return ("\(count)", "")
    }

    /// 缩放并保留精度：≥100 取整，否则保留一位小数
    private static func scaled(_ count: Int, by divisor: Double) -> String {
        let value = Double(count) / divisor
        return value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    // MARK: 扫描与解析（后台线程执行）

    nonisolated private static func scanSessionFiles() -> [LocalUsageDay] {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["KIMI_CODE_HOME"] ?? (NSHomeDirectory() + "/.kimi-code")
        let sessionsURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var byDay: [Date: LocalUsageDay] = [:]
        let calendar = Calendar.current

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "wire.jsonl",
                  fileURL.path.contains("/agents/") else { continue }
            autoreleasepool {
                guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                      let text = String(data: data, encoding: .utf8) else { return }
                text.enumerateLines { line, _ in
                    // 先子串粗筛，命中才走 JSON 解析（usage.record 行占比很低）
                    guard line.contains("\"usage.record\""),
                          let lineData = line.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          event["type"] as? String == "usage.record",
                          let usage = event["usage"] as? [String: Any],
                          let timeMs = (event["time"] as? NSNumber)?.doubleValue else { return }

                    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: timeMs / 1000))
                    var entry = byDay[day] ?? LocalUsageDay(date: day)
                    let cacheRead = (usage["inputCacheRead"] as? NSNumber)?.intValue ?? 0
                    entry.input += ((usage["inputOther"] as? NSNumber)?.intValue ?? 0)
                        + cacheRead
                        + ((usage["inputCacheCreation"] as? NSNumber)?.intValue ?? 0)
                    entry.output += (usage["output"] as? NSNumber)?.intValue ?? 0
                    entry.cacheRead += cacheRead
                    byDay[day] = entry
                }
            }
        }

        return byDay.values.sorted { $0.date < $1.date }
    }
}

// MARK: - 本地用量卡片

/// 「本地用量」卡片：使用 Token 大数字 + 缓存命中率 + 按天柱状图（悬停出 tooltip）。
/// 范围三档：累计（默认）/ 今日 / 7天，选择持久化到 localUsageRange。
struct LocalUsageCard: View {
    @StateObject private var service = KimiLocalUsageService.shared
    @StateObject private var languageManager = LanguageManager.shared
    @AppStorage("localUsageRange") private var rangeRaw: String = LocalUsageRange.all.rawValue
    @State private var hoveredDay: LocalUsageDay?
    @State private var hoveredSegment: LocalUsageRange?

    private let chartHeight: CGFloat = 44
    private let tooltipZoneHeight: CGFloat = 26

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private var range: LocalUsageRange {
        LocalUsageRange(rawValue: rangeRaw) ?? .all
    }

    private var filteredDays: [LocalUsageDay] {
        service.days(in: range)
    }

    /// 首次扫描进行中（尚未拿到任何结果）：整张卡片内容区展示骨架屏；
    /// 后续刷新复用上次结果，不闪烁。
    private var isLoadingFirstTime: Bool {
        service.isLoading && !service.hasScanned
    }

    /// 图表展示的天数：累计档限制为近 30 个自然日（全历史柱子太密不好看），
    /// 大数字仍按全量累计；其余范围与 filteredDays 一致
    private var chartDays: [LocalUsageDay] {
        guard range == .all else { return filteredDays }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: Date())) ?? .distantPast
        return filteredDays.filter { $0.date >= start }
    }

    /// 指标标签随范围联动：累计使用 Token / 今日使用 Token / 7 天使用 Token
    private var metricsLabelKey: String {
        switch range {
        case .all: return "累计使用 Token"
        case .today: return "今日使用 Token"
        case .week: return "7 天使用 Token"
        }
    }

    private var totalTokens: Int {
        filteredDays.reduce(0) { $0 + $1.totalTokens }
    }

    /// 所选范围无记录时命中率为 nil（显示 --）
    private var cacheHitRate: Double? {
        let input = filteredDays.reduce(0) { $0 + $1.input }
        guard input > 0 else { return nil }
        let cacheRead = filteredDays.reduce(0) { $0 + $1.cacheRead }
        return Double(cacheRead) / Double(input)
    }

    private var maxDayTokens: Int {
        chartDays.map(\.totalTokens).max() ?? 0
    }

    private var formattedTokens: (value: String, unit: String) {
        KimiLocalUsageService.formatTokenCount(totalTokens)
    }

    private var cacheHitRateText: String {
        guard let cacheHitRate else { return "--" }
        return String(format: "%.1f%%", cacheHitRate * 100)
    }

    /// 柱子密度随根数调整：累计（几十根）用窄柱密排，7天/今日用宽柱
    private var barSpacing: CGFloat { chartDays.count > 20 ? 2 : 6 }
    private var barCornerRadius: CGFloat { chartDays.count > 20 ? 1 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if isLoadingFirstTime {
                // 首次扫描：内容区整体骨架（大数字 + 图表），避免 0 值闪现
                metricsSkeleton
                chartSkeleton
            } else {
                metricsRow
                chartArea
            }
        }
        .padding(14)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 标题 + 范围切换

    private var headerRow: some View {
        HStack {
            LText("本地用量")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Spacer()

            rangePicker
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(LocalUsageRange.allCases) { item in
                let isSelected = range == item
                let isHovered = hoveredSegment == item
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? Color.kimiTextPrimary : Color.kimiTextSecondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.kimiBlue : Color.kimiTextPrimary.opacity(isHovered ? 0.08 : 0))
                    )
                    .contentShape(Capsule())
                    .onTapGesture { rangeRaw = item.rawValue }
                    .onHover { hoveredSegment = $0 ? item : nil }
                    .cursor(.pointingHand)
            }
        }
        .padding(2)
        .background(Color.kimiTextPrimary.opacity(0.06))
        .clipShape(Capsule())
    }

    // MARK: 指标行（使用 Token + 缓存命中率）

    private var metricsRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(formattedTokens.value)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.kimiTextPrimary)
                    if !formattedTokens.unit.isEmpty {
                        Text(formattedTokens.unit)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.kimiTextPrimary)
                    }
                }

                LText(metricsLabelKey)
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(cacheHitRateText)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.green)

                LText("缓存命中率")
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
            }
        }
    }

    // MARK: 柱状图（按天，悬停出 tooltip）

    @ViewBuilder
    private var chartArea: some View {
        if filteredDays.isEmpty {
            // 空态：所选范围完全无记录（大数字同为 0，口径一致）
            LText("暂无会话记录")
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight + tooltipZoneHeight)
        } else if chartDays.isEmpty {
            // 仅累计档可能出现：历史有记录但近 30 天无记录
            LText("近 30 天暂无记录")
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight + tooltipZoneHeight)
        } else {
            barChart
        }
    }

    // MARK: 骨架屏（首次扫描未完成时展示，结构与 metricsRow / barChart 对齐）

    /// 与 metricsRow 布局一致：左侧大数字占位 + 右侧命中率占位
    private var metricsSkeleton: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                skeletonBlock(width: 84, height: 22)
                skeletonBlock(width: 60, height: 12)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                skeletonBlock(width: 50, height: 22)
                skeletonBlock(width: 48, height: 12)
            }
        }
    }

    /// 与 barChart 占位高度一致
    private var chartSkeleton: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.kimiTextPrimary.opacity(0.06))
            .frame(height: chartHeight + tooltipZoneHeight)
    }

    private func skeletonBlock(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.kimiTextPrimary.opacity(0.08))
            .frame(width: width, height: height)
    }

    private var barChart: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(chartDays) { day in
                        RoundedRectangle(cornerRadius: barCornerRadius)
                            .fill(barColor(for: day))
                            .frame(maxWidth: .infinity)
                            .frame(height: barHeight(for: day))
                            .onHover { isHovered in
                                hoveredDay = isHovered ? day : nil
                            }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)

                if let hoveredDay {
                    tooltipView(for: hoveredDay)
                        .position(tooltipPosition(for: hoveredDay, in: proxy.size))
                }
            }
        }
        .frame(height: chartHeight + tooltipZoneHeight)
    }

    private func barHeight(for day: LocalUsageDay) -> CGFloat {
        guard maxDayTokens > 0 else { return 1 }
        // 0 值天保留 1px 底线，视觉上不断流
        return max(1, CGFloat(day.totalTokens) / CGFloat(maxDayTokens) * chartHeight)
    }

    private func barColor(for day: LocalUsageDay) -> Color {
        if hoveredDay?.id == day.id { return .kimiBlue }
        if day.totalTokens == maxDayTokens { return .kimiBlue }
        return .kimiBlue.opacity(0.35)
    }

    private func tooltipView(for day: LocalUsageDay) -> some View {
        let formatted = KimiLocalUsageService.formatTokenCount(day.totalTokens)
        let dateText = Self.monthDayFormatter.string(from: day.date)
        return VStack(spacing: 0) {
            Text("\(dateText) · \(formatted.value)\(formatted.unit)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.kimiPanelBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.kimiTextPrimary.opacity(0.15), lineWidth: 0.5)
                )

            TooltipTriangle()
                .fill(Color.kimiPanelBackground)
                .frame(width: 10, height: 5)
        }
    }

    private func tooltipPosition(for day: LocalUsageDay, in size: CGSize) -> CGPoint {
        let count = chartDays.count
        let index = chartDays.firstIndex(where: { $0.id == day.id }) ?? 0
        let centerX = size.width * (CGFloat(index) + 0.5) / CGFloat(max(count, 1))
        // tooltip 宽约 96，clamp 防止贴边时超出卡片
        let clampedX = min(max(centerX, 48), size.width - 48)
        return CGPoint(x: clampedX, y: tooltipZoneHeight / 2)
    }
}

/// tooltip 下方的小三角
private struct TooltipTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
