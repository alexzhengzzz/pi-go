import SwiftUI
import AppKit
import CoreImage

struct Session: Decodable, Identifiable {
    var id: String
    var socket: String
    var cwd: String
    var name: String?
    var shared: Bool
    var model: Model?
    struct Model: Decodable { var name: String; var provider: String }
}
struct Workspace: Decodable, Identifiable {
    var id: String { cwd }
    let registrationID: String?
    let name: String
    let cwd: String

    enum CodingKeys: String, CodingKey {
        case registrationID = "id"
        case name, cwd
    }
}

struct HistorySession: Decodable, Identifiable {
    var id: String { "\(agent ?? "pi"):\(sessionID)" }
    let sessionID: String
    let cwd: String
    let agent: String?
    let name: String?
    let modified: String?
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case cwd, agent, name, modified, active
    }
}

struct Bridge: Decodable {
    var running: Bool
    var paired: Bool?
    var lastSeen: Double?
    var expiresAt: Double?
    var host: String?
    var address: String?
}
struct Services: Decodable {
    var hostRunning: Bool
    var managed: Bool
    var tunnelRunning: Bool?
    var usbAuto: Bool?
}
struct Payload: Decodable {
    var workspaces: [Workspace]?
    var history: [HistorySession]?
    var nextCursor: Int?
    var sessions: [Session]?
    var addresses: [String]?
    var bridge: Bridge?
    var services: Services?
    var code: String?
    var bundle: String?
    var warning: String?
}
struct Result: Decodable { var ok: Bool; var data: Payload?; var error: String? }

@MainActor final class PairingModel: ObservableObject {
    @Published var mode = UserDefaults.standard.string(forKey: "connectionMode") ?? "lan" {
        didSet {
            UserDefaults.standard.set(mode, forKey: "connectionMode")
        }
    }
    @Published var autoUSB = UserDefaults.standard.bool(forKey: "autoUSB") {
        didSet {
            UserDefaults.standard.set(autoUSB, forKey: "autoUSB")
        }
    }
    @Published var host = UserDefaults.standard.string(forKey: "lanHost") ?? ""
    @Published var publicIP = UserDefaults.standard.string(forKey: "publicIP") ?? ""
    @Published var publicPort = UserDefaults.standard.string(forKey: "publicPort") ?? "8443"
    @Published var sessions: [Session] = []
    @Published var addresses: [String] = []
    @Published var bridge = Bridge(running: false)
    @Published var services: Services?
    @Published var code = ""
    @Published var bundle = ""
    @Published var notice = ""
    @Published var error = ""
    @Published var busy = false
    private var polling = false

    static func request(_ input: [String: String]) async throws -> Payload {
        let encoded = try JSONSerialization.data(withJSONObject: input)
        return try await Task.detached {
            let resources = Bundle.main.resourceURL!
            let node = try String(contentsOf: resources.appendingPathComponent("node-path"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [resources.appendingPathComponent("desktop/pairing-control.mjs").path]
            var env = ProcessInfo.processInfo.environment
            env["PIGO_APP_RESOURCES"] = resources.path
            env["PATH"] = "\(URL(fileURLWithPath: node).deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let output = Pipe(), input = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardInput = input; process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(encoded); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let response = try? JSONDecoder().decode(Result.self, from: data) else {
                throw NSError(domain: "PiGo", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法启动配对服务，请重新构建应用并检查 Node.js。"])
            }
            guard response.ok, let payload = response.data else {
                throw NSError(domain: "PiGo", code: 1, userInfo: [NSLocalizedDescriptionKey: response.error ?? "操作失败"])
            }
            return payload
        }.value
    }
    func refresh() async {
        guard !polling && !busy else { return }
        polling = true
        let selectedMode = mode
        defer { polling = false }
        do {
            let payload = try await Self.request(["action": "refresh", "mode": selectedMode])
            guard selectedMode == mode && !busy else { return }
            sessions = payload.sessions ?? []; addresses = payload.addresses ?? []
            bridge = payload.bridge ?? Bridge(running: false)
            services = payload.services
            if selectedMode == "lan" && !addresses.contains(host) {
                host = bridge.host.flatMap { addresses.contains($0) ? $0 : nil } ?? addresses.first ?? ""
            }
            if selectedMode == "remote", let address = bridge.address {
                let endpoint = address.split(separator: ":", maxSplits: 1)
                publicIP = String(endpoint[0])
                publicPort = endpoint.count == 2 ? String(endpoint[1]) : "443"
            }
            if (!code.isEmpty || !bundle.isEmpty) && (bridge.expiresAt ?? 0) < Date().timeIntervalSince1970 * 1000 {
                code = ""; bundle = ""; notice = ""
            }
        } catch { self.error = error.localizedDescription }
    }
    func perform(_ action: String, session: Session? = nil, usbEnabled: Bool? = nil) async {
        guard !busy else { return }
        busy = true; error = ""
        var input = ["action": action, "mode": mode, "host": host]
        if mode == "remote" {
            input["publicIP"] = publicIP.trimmingCharacters(in: .whitespacesAndNewlines)
            input["publicPort"] = publicPort.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let session { input["socket"] = session.socket; input["id"] = session.id }
        if mode == "usb" && action == "takeover" { input["enabled"] = String(autoUSB) }
        if let usbEnabled { input["enabled"] = String(usbEnabled) }
        do {
            let payload = try await Self.request(input)
            if action == "pair" || action == "connect" {
                notice = payload.warning ?? ""
                code = payload.code ?? ""
                bundle = payload.bundle ?? ""
                if mode == "lan" { UserDefaults.standard.set(host, forKey: "lanHost") }
                if mode == "remote" {
                    UserDefaults.standard.set(input["publicIP"], forKey: "publicIP")
                    UserDefaults.standard.set(input["publicPort"], forKey: "publicPort")
                }
            }
            if action == "revoke" || action == "stop" { code = ""; bundle = ""; notice = "" }
            if mode == "usb" && action == "stop" { autoUSB = false }
            if let usbEnabled { autoUSB = usbEnabled }
            if let value = payload.bridge { bridge = value }
            if let value = payload.services { services = value }
        } catch { self.error = error.localizedDescription }
        busy = false
        await refresh()
    }
    var status: String {
        if !bridge.running { return mode == "usb" && autoUSB ? "等待 USB 手机" : "尚未连接" }
        if let last = bridge.lastSeen, bridge.paired == true, Date().timeIntervalSince1970 * 1000 - last < 15000 { return "手机在线" }
        return bridge.paired == true ? "已配对 · 等待手机连接" : "服务已启动 · 等待手机配对"
    }
    var connectLabel: String {
        if mode == "usb" { return bridge.paired == true ? "重新连接" : "连接手机" }
        if bridge.running { return "生成新配对码" }
        return mode == "remote" ? "启动公网配对" : "启动局域网服务"
    }
    var qr: NSImage? {
        guard !bundle.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(bundle.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let rect = image.extent.insetBy(dx: -4, dy: -4)
        let padded = image.composited(over: CIImage(color: .white).cropped(to: rect)).transformed(by: .init(scaleX: 5, y: 5))
        guard let bitmap = CIContext().createCGImage(padded, from: padded.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}

struct PairingView: View {
    @StateObject var model = PairingModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "iphone.and.arrow.forward").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("连接手机").font(.title.bold())
                    Text("Pi Go · \(model.status)").foregroundStyle(.secondary)
                    if let services = model.services {
                        Text(services.hostRunning ? "后台宿主运行中" : "后台宿主未启用")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text("配对后，手机自动显示这台电脑的全部 Pi 会话和历史记录。").font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("连接方式", selection: $model.mode) {
                        Text("局域网扫码").tag("lan")
                        Text("公网").tag("remote")
                        Text("USB").tag("usb")
                    }.pickerStyle(.segmented).disabled(model.busy)
                    if model.mode == "lan" {
                        Text("手机和电脑连接同一 Wi-Fi，在手机 Pi Go 中选择「局域网 → 扫码导入」。").foregroundStyle(.secondary)
                        Picker("电脑地址", selection: $model.host) {
                            if model.addresses.isEmpty { Text("未找到局域网地址").tag("") }
                            ForEach(model.addresses, id: \.self) { Text($0).tag($0) }
                        }.disabled(model.busy)
                    } else if model.mode == "remote" {
                        HStack {
                            TextField("VPS 公网 IPv4", text: $model.publicIP)
                            TextField("端口", text: $model.publicPort).frame(width: 75)
                        }.textFieldStyle(.roundedBorder).disabled(model.busy || model.bridge.running)
                        Text(model.services?.tunnelRunning == true ? "本机 SSH 隧道进程运行中" : "使用已配置的 VPS SSH 隧道转发至本机端口 18982。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("插线自动连接", isOn: Binding(
                            get: { model.services?.usbAuto ?? false },
                            set: { enabled in Task { await model.perform("usb-auto", usbEnabled: enabled) } }
                        )).disabled(model.busy || model.services?.managed != true)
                        Text("通过 USB 连接一台已配对且允许调试的手机。退出 App 后也可自动恢复连接。").foregroundStyle(.secondary)
                    }
                    Button(model.connectLabel) {
                        Task { await model.perform(model.mode != "usb" && model.bridge.running ? "pair" : "connect") }
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.busy || (model.mode == "lan" && model.host.isEmpty) ||
                            (model.mode == "remote" && (model.publicIP.isEmpty || model.publicPort.isEmpty)))
                    if model.services?.managed != true {
                        Button("接管连接服务") { Task { await model.perform("takeover") } }
                            .disabled(model.busy || (model.mode == "lan" && model.host.isEmpty) ||
                                (model.mode == "remote" && (model.publicIP.isEmpty || model.publicPort.isEmpty)))
                    }
                    if model.bridge.running {
                        HStack {
                            if model.mode == "usb" && model.bridge.paired == true {
                                Button("重新配对") { Task { await model.perform("pair") } }
                            }
                            Button("撤销手机配对", role: .destructive) { Task { await model.perform("revoke") } }
                            Button("停用连接") { Task { await model.perform("stop") } }
                        }.disabled(model.busy)
                    }
                    Text("关闭窗口后服务继续运行。配对成功后手机会保存连接。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 10) {
                    if let qr = model.qr {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 225, height: 225)
                        Text("扫码后在手机点「配对并连接」").font(.caption)
                    } else if !model.code.isEmpty {
                        Text(model.code).font(.system(size: 34, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text("在手机 Pi Go 中输入八位配对码").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: model.mode == "usb" ? "cable.connector" : "qrcode").font(.system(size: 65)).foregroundStyle(.tertiary)
                        Text(model.status).foregroundStyle(.secondary)
                    }
                    if !model.code.isEmpty || !model.bundle.isEmpty {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("剩余 \(max(0, Int((model.bridge.expiresAt ?? 0) / 1000 - context.date.timeIntervalSince1970))) 秒").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(width: 250, height: 270).background(.white, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
            }
            Divider()
            HStack { Text("正在运行的会话").font(.headline); Spacer(); Button("刷新") { Task { await model.refresh() } }.disabled(model.busy) }
            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("暂未发现运行中的会话")
                    Text("从手机打开历史记录，或直接接入已加载 Pi Go 扩展的 Mac 会话。").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.sessions, id: \.socket) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.name ?? URL(fileURLWithPath: session.cwd).lastPathComponent).fontWeight(.medium)
                                    Text(session.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    if let m = session.model { Text("\(m.name) · \(m.provider)\(m.provider == "pi-go-test" ? " · 离线测试模型" : "")").font(.caption).foregroundStyle(m.provider == "pi-go-test" ? .orange : .secondary) }
                                }
                                Spacer()
                                Text("自动同步").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            if !model.error.isEmpty { Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(26).frame(minWidth: 760, idealWidth: 800, minHeight: 620, idealHeight: 700)
        .task { while !Task.isCancelled { await model.refresh(); try? await Task.sleep(for: .seconds(3)) } }
        .onChange(of: model.mode) { _, _ in model.code = ""; model.bundle = ""; model.notice = ""; model.bridge = Bridge(running: false); model.services = nil; model.error = ""; Task { await model.refresh() } }
    }
}

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var history: [HistorySession] = []
    @Published var nextCursor: Int?
    @Published var busy = false
    @Published var error = ""
    @Published var loaded = false

    func run(_ action: String = "workspace-library", fields: [String: String] = [:]) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            if action != "workspace-library" {
                var input = fields
                input["action"] = action
                _ = try await PairingModel.request(input)
            }
            let response = try await PairingModel.request(["action": "workspace-library", "scope": "workspaces"])
            workspaces = response.workspaces ?? []
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadHistory(cwd: String, more: Bool = false) async {
        guard !busy, !more || nextCursor != nil else { return }
        busy = true
        error = ""
        defer { busy = false }
        if !more {
            history = []
            nextCursor = nil
        }
        let input = ["action": "workspace-library", "scope": "workspace",
                     "cursor": String(nextCursor ?? 0), "cwd": cwd]
        do {
            let response = try await PairingModel.request(input)
            let seen = Set(history.map(\.id))
            history += (response.history ?? []).filter { !seen.contains($0.id) }
            nextCursor = response.nextCursor
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteSession(_ session: HistorySession) async {
        guard !busy else { return }
        var input = ["action": "delete-session", "cwd": session.cwd, "id": session.sessionID]
        input["agent"] = session.agent
        busy = true
        do {
            _ = try await PairingModel.request(input)
        } catch {
            busy = false
            self.error = error.localizedDescription
            return
        }
        busy = false
        await loadHistory(cwd: session.cwd)
    }
}

struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @State private var selection: String?
    @State private var pendingRename: Workspace?
    @State private var nameDraft = ""
    @State private var pendingDeletion: Deletion?

    private enum Deletion {
        case workspace(Workspace, String)
        case session(HistorySession)

        var title: String {
            switch self {
            case .workspace: "移除工作区？"
            case .session: "删除会话？"
            }
        }

        var detail: String {
            switch self {
            case .workspace(let workspace, _):
                "将移除「\(workspace.name)」的登记并关闭 Pi Go 托管的会话。项目文件和会话历史会保留。"
            case .session(let session):
                "将「\(session.name ?? "未命名会话")」移入废纸篓。"
            }
        }

        @MainActor func perform(using model: WorkspaceModel) async {
            switch self {
            case .workspace(_, let id):
                await model.run("remove-workspace", fields: ["id": id])
            case .session(let session):
                await model.deleteSession(session)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("工作区").font(.title2.bold())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("添加到工作区", systemImage: "folder.badge.plus", action: addWorkspace)
                    .disabled(model.busy)
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task {
                        await model.run()
                        if let selection, model.error.isEmpty {
                            await model.loadHistory(cwd: selection)
                        }
                    }
                }
                    .disabled(model.busy)
            }.padding(16)
            if !model.error.isEmpty {
                Text(model.error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(model.workspaces) { workspace in
                        Label(workspace.name, systemImage: "folder").tag(workspace.id)
                    }
                }
                .listStyle(.sidebar)
                .disabled(model.busy)
                .frame(minWidth: 170, idealWidth: 235, maxWidth: 280, maxHeight: .infinity)
                Group {
                    if let workspace = model.workspaces.first(where: { $0.id == selection }) {
                        workspaceDetails(workspace)
                    } else if model.loaded {
                        ContentUnavailableView(model.workspaces.isEmpty ? "还没有工作区" : "选择工作区",
                                               systemImage: "folder")
                    } else if model.busy {
                        ProgressView("正在读取工作区")
                    } else {
                        ContentUnavailableView("无法读取工作区", systemImage: "folder.badge.questionmark")
                    }
                }
                .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { await model.run() }
        .onChange(of: model.workspaces.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onChange(of: selection) { _, target in
            if let target { Task { await model.loadHistory(cwd: target) } }
        }
        .alert("编辑工作区名称", isPresented: Binding(get: { pendingRename != nil }, set: {
            if !$0 { pendingRename = nil }
        }), presenting: pendingRename) { workspace in
            TextField("显示名称", text: $nameDraft)
            Button("保存") {
                guard let id = workspace.registrationID else { return }
                let name = nameDraft
                Task { await model.run("rename-workspace", fields: ["id": id, "name": name]) }
            }.disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .alert(pendingDeletion?.title ?? "", isPresented: Binding(get: { pendingDeletion != nil }, set: {
            if !$0 { pendingDeletion = nil }
        }), presenting: pendingDeletion) { deletion in
            Button("确认", role: .destructive) { Task { await deletion.perform(using: model) } }
            Button("取消", role: .cancel) {}
        } message: { deletion in
            Text(deletion.detail)
        }
    }

    private func addWorkspace() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "添加"
        guard picker.runModal() == .OK, let path = picker.url?.path else { return }
        Task { await model.run("add-workspace", fields: ["cwd": path]) }
    }

    private func workspaceDetails(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.name).font(.title2.bold())
                Spacer()
                if let id = workspace.registrationID {
                    Menu("工作区操作") {
                        Button("编辑名称") {
                            nameDraft = workspace.name
                            pendingRename = workspace
                        }
                        Button("移除工作区", role: .destructive) {
                            pendingDeletion = .workspace(workspace, id)
                        }
                    }.disabled(model.busy)
                }
            }
            Text(workspace.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            historyList(cwd: workspace.cwd)
        }
        .padding(16)
    }

    @ViewBuilder private func historyList(cwd: String) -> some View {
        if model.history.isEmpty {
            if model.busy {
                ProgressView("正在读取会话")
            } else {
                ContentUnavailableView("暂无会话", systemImage: "bubble")
            }
        } else {
            List {
                ForEach(model.history) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(session.name ?? "未命名会话")
                                if let agent = session.agent, agent != "pi" {
                                    Text(agent == "codex" ? "Codex" : agent == "agy" ? "AGY" : agent.uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            if let modified = session.modified, let date = ISO8601DateFormatter.sessionDate.date(from: modified) {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if session.active {
                            Text("已打开").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Menu {
                                Button("删除会话", role: .destructive) {
                                    pendingDeletion = .session(session)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }.menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("会话操作").disabled(model.busy)
                        }
                    }
                    .padding(.vertical, 5)
                }
                if model.nextCursor != nil {
                    Button("加载更多") {
                        Task { await model.loadHistory(cwd: cwd, more: true) }
                    }.disabled(model.busy)
                }
            }
            .listStyle(.plain)
        }
    }
}

private extension ISO8601DateFormatter {
    static let sessionDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

@main enum PiGoMain {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--pigo-screen-capture" {
            // Bound the lifetime of the hidden instance even if WindowServer stops responding.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { exit(1) }
            await ScreenCapture.writeResult(to: URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        PiGoApp.main()
    }
}

struct PiGoApp: App {
    var body: some Scene {
        Window("Pi Go", id: "pairing") {
            TabView {
                WorkspaceView().tabItem { Label("工作区", systemImage: "folder") }
                PairingView().tabItem { Label("连接手机", systemImage: "iphone.and.arrow.forward") }
            }.frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 800, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("授权电脑截图") {
                    if !CGPreflightScreenCaptureAccess() {
                        _ = CGRequestScreenCaptureAccess()
                    }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
