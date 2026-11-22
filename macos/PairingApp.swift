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

    func request(_ input: [String: String]) async throws -> Payload {
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
            let payload = try await request(["action": "refresh", "mode": selectedMode])
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
            let payload = try await request(input)
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
                    Text("从手机打开历史记录，或在 Mac 的 Pi CLI 使用 /pi-go-share 共享当前会话。").font(.callout).foregroundStyle(.secondary)
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

@main struct PiGoApp: App {
    var body: some Scene {
        Window("Pi Go — 连接手机", id: "pairing") { PairingView() }
            .defaultSize(width: 800, height: 700)
    }
}
