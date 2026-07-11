import SwiftUI
import AppKit

@main
struct KimiBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            KimiMenu()
        } label: {
            KimiLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

struct KimiLabel: View {
    @StateObject private var model = KimiBarModel.shared

    var body: some View {
        if let quota = model.quota {
            Image(nsImage: MenuBarTextRenderer.image(
                weekly: quota.weekly.percentage,
                fiveHour: quota.fiveHour.percentage
            ))
        } else {
            Text(model.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}

@MainActor
enum MenuBarTextRenderer {
    static func image(weekly: Int, fiveHour: Int) -> NSImage {
        let content = VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 3) {
                Text("7D")
                    .frame(width: 20, alignment: .leading)
                Text("\(weekly)\u{2009}%")
                    .frame(width: 32, alignment: .trailing)
            }
            HStack(spacing: 3) {
                Text("5H")
                    .frame(width: 20, alignment: .leading)
                Text("\(fiveHour)\u{2009}%")
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .default))
        .monospacedDigit()
        .foregroundStyle(Color(red: 0.886, green: 0.910, blue: 0.961))
        .frame(width: 55, height: 22, alignment: .trailing)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let nsImage = renderer.nsImage else {
            return NSImage(size: NSSize(width: 56, height: 22))
        }
        nsImage.isTemplate = false
        return nsImage
    }
}

struct KimiMenu: View {
    @StateObject private var model = KimiBarModel.shared
    @State private var showSettings = false
    @State private var kimiVersion = "检测中…"

    private let consoleURL = URL(string: "https://www.kimi.com/code/console")!
    private let githubURL = URL(string: "https://github.com/xifandev/KimiBar")!

    var body: some View {
        VStack(spacing: 0) {
            // 1. 统计区域
            if let quota = model.quota {
                QuotaDashboard(quota: quota, isLoading: model.isLoading)
                    .padding(.top, 20)
            } else {
                Text(model.text)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding(.top, 20)
            }

            // 2. 分割线
            Divider()
                .padding(.vertical, 16)

            // 3. 操作按钮
            HStack(spacing: 10) {
                Button(action: { model.refresh() }) {
                    Text("刷新")
                        .font(.system(size: 13))
                }
                .disabled(model.key.isEmpty || model.isLoading)
                .controlSize(.small)
                .cursor(.pointingHand)

                Spacer()

                Button(action: { showSettings = true }) {
                    Text("设置")
                        .font(.system(size: 13))
                }
                .controlSize(.small)
                .cursor(.pointingHand)

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Text("退出")
                        .font(.system(size: 13))
                }
                .controlSize(.small)
                .cursor(.pointingHand)
            }

            // 4. 快捷链接
            HStack(spacing: 16) {
                ShortcutLink(
                    title: "KimiCode 控制台",
                    icon: "link",
                    url: consoleURL
                )

                ShortcutLink(
                    title: "GitHub",
                    icon: "github-icon",
                    url: githubURL,
                    isCustomIcon: true
                )

                Spacer()
            }
            .padding(.top, 14)

            // 5. 分割线
            Divider()
                .padding(.vertical, 14)

            // 6. 底部 KimiCode 版本号
            HStack {
                Text("KimiCode Version \(formatKimiVersion(kimiVersion))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.7))

                Spacer()
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 18)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsView()
        }
        .onAppear {
            loadKimiVersion()
        }
    }

    private func loadKimiVersion() {
        Task {
            let version = await detectKimiCLIVersion()
            await MainActor.run {
                kimiVersion = version
            }
        }
    }

    private func detectKimiCLIVersion() async -> String {
        let result = await runKimiCommand(arguments: ["--version"])
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty || output.contains("No such file") ? "未检测到" : output
    }

    private func runKimiCommand(arguments: [String]) async -> (output: String, exitCode: Int32) {
        return await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let candidates = [
                "kimi",
                "\(home)/.kimi-code/bin/kimi",
                "\(home)/.kimi/bin/kimi",
                "/usr/local/bin/kimi",
                "/opt/homebrew/bin/kimi"
            ]

            for kimiPath in candidates {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                let argsString = arguments.map { "\($0)" }.joined(separator: " ")
                task.arguments = ["-lc", "\(kimiPath) \(argsString)"]

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                    if task.terminationStatus == 0 {
                        return (trimmed, 0)
                    }

                    let lower = trimmed.lowercased()
                    if lower.contains("no such file") || lower.contains("command not found") || lower.contains("permission denied") {
                        continue
                    }

                    return (trimmed, task.terminationStatus)
                } catch {
                    continue
                }
            }
            return ("", -1)
        }.value
    }

    private func formatKimiVersion(_ version: String) -> String {
        guard version != "未检测到" else { return "未检测到" }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if let last = components.last {
            return String(last)
        }
        return version
    }
}

struct SettingsView: View {
    @StateObject private var model = KimiBarModel.shared
    @State private var editingKey = ""
    @State private var isEditingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Key")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if isEditingKey || model.key.isEmpty {
                HStack(spacing: 10) {
                    SecureField("sk-kimi-...", text: $editingKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onChange(of: editingKey) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed != newValue {
                                editingKey = trimmed
                            }
                        }

                    Button(action: saveKey) {
                        Text("保存")
                            .font(.system(size: 13))
                    }
                    .disabled(editingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .cursor(.pointingHand)
                }
            } else {
                HStack(spacing: 10) {
                    Text(maskedKey(model.key))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button(action: {
                        editingKey = model.key
                        isEditingKey = true
                    }) {
                        Text("修改")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .cursor(.pointingHand)
                }
                .frame(maxWidth: .infinity)
            }

            if let error = model.errorMessage {
                ErrorMessageView(message: error)
            }
        }
        .frame(width: 320)
        .padding(20)
        .onAppear {
            editingKey = model.key
            isEditingKey = model.key.isEmpty
        }
    }

    private func saveKey() {
        let trimmed = editingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        editingKey = trimmed
        model.key = trimmed
        isEditingKey = false
        model.refresh()
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }
        let prefix = String(key.prefix(7))
        let suffix = String(key.suffix(5))
        return "\(prefix)...\(suffix)"
    }
}

struct ShortcutLink: View {
    let title: String
    let icon: String
    let url: URL
    var isCustomIcon: Bool = false
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5) {
                if isCustomIcon {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                }
                Text(title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.accent)
        .cursor(.pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

struct ErrorMessageView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.9))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("复制错误信息")
            .padding(.top, 2)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct LoadingRing: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .foregroundStyle(.white.opacity(0.7))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct StatusTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct QuotaDashboard: View {
    let quota: KimiQuota
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 0) {
            StatColumn(
                title: "本周用量",
                value: quota.weekly.percentage,
                reset: quota.weekly.timeUntilReset,
                color: .blue,
                isLoading: isLoading
            )

            Divider()
                .frame(height: 56)
                .padding(.horizontal, 16)

            StatColumn(
                title: "5小时用量",
                value: quota.fiveHour.percentage,
                reset: quota.fiveHour.timeUntilReset,
                color: .orange,
                isLoading: isLoading
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct StatColumn: View {
    let title: String
    let value: Int
    let reset: String
    let color: Color
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack {
                if !isLoading {
                    Text("\(value)%")
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }

                if isLoading {
                    LoadingRing()
                        .frame(width: 26, height: 26)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .frame(width: 80, height: 44)
            .animation(.easeInOut(duration: 0.2), value: isLoading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 3)
                        .foregroundStyle(.secondary.opacity(0.15))

                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(min(value, 100)) / 100, height: 3)
                        .foregroundStyle(color)
                }
            }
            .frame(width: 72, height: 3)

            Text(reset)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
final class KimiBarModel: ObservableObject {
    static let shared = KimiBarModel()

    @AppStorage("kimiApiKey") var key = ""
    @Published var text = "-- · --"
    @Published var quota: KimiQuota?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let service = KimiQuotaService()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        timer?.tolerance = 10
    }

    func refresh() {
        guard !key.isEmpty else {
            text = "未配置"
            quota = nil
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        let startTime = Date()

        Task {
            let result = await service.fetchQuota(key: key)

            // 保证至少转 0.5 秒，体验更优雅
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, 0.5 - elapsed)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let quota):
                    self.quota = quota
                    self.text = "周 \(quota.weekly.percentage)% · 5h \(quota.fiveHour.percentage)%"
                    self.errorMessage = nil
                case .failure(let error):
                    if self.quota == nil {
                        self.text = "--"
                    }
                    self.errorMessage = errorDescription(error)
                }
            }
        }
    }

    private func errorDescription(_ error: QuotaError) -> String {
        switch error {
        case .invalidKeyFormat:
            return "API Key 格式错误，应以 sk-kimi- 开头"
        case .invalidURL:
            return "请求地址无效"
        case .networkError(let msg):
            return "网络错误：\(msg)"
        case .httpError(let code, let msg):
            return "Kimi API 返回错误（\(code)）：\(msg)"
        case .invalidResponse:
            return "无法解析 API 返回数据"
        }
    }
}
