import SwiftUI
import NPVCore

struct ConnectionView: View {
    @ObservedObject var controller: TunnelController
    @State private var showConfiguration = false
    @State private var showScenarios = false
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                List {
                    modeBanner
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(controller.stateLabel, systemImage: controller.state == .connected ? "network" : "network.slash")
                                .font(.title2.weight(.semibold)).accessibilityIdentifier("connection.status")
                            Text(controller.profile?.name ?? "添加服务器后开始连接").foregroundStyle(.secondary)
                            if let action = controller.pendingAction {
                                ProgressView(action == .connect ? "等待连接确认…" : "等待断开确认…")
                            }
                            if controller.state.canStop || controller.pendingAction == .connect {
                                Button("断开连接", role: .destructive) { controller.disconnect() }
                                    .buttonStyle(.bordered).disabled(controller.busy).accessibilityIdentifier("connection.stop")
                            } else {
                                Button(controller.isSimulation ? "模拟连接" : "连接服务器") { Task { await controller.connect() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!controller.ready || controller.busy || controller.pendingAction != nil || controller.profile == nil || !controller.state.canEdit)
                                    .accessibilityIdentifier("connection.start")
                            }
                        }.padding(.vertical, 8)
                    }
                    messages
                    if controller.profile == nil {
                        Section("首次使用") {
                            Label("生成设备身份", systemImage: controller.identityID == nil ? "1.circle" : "checkmark.circle")
                            Label("填写并保存服务器配置", systemImage: "2.circle")
                            Button("前往配置") { selectedTab = 1 }.accessibilityIdentifier("connection.setup")
                        }
                    }
                    Section(controller.isSimulation ? "模拟统计" : "隧道统计") {
                        if let stats = controller.stats {
                            LabeledContent("接收", value: bytes(stats.receivedBytes))
                            LabeledContent("发送", value: bytes(stats.sentBytes))
                            if let timestamp = stats.lastHandshakeUnixSeconds {
                                LabeledContent(controller.isSimulation ? "模拟握手时间" : "最近成功握手") {
                                    Text(Date(timeIntervalSince1970: Double(timestamp)), style: .time)
                                }
                            } else {
                                Text("尚未观察到成功握手").foregroundStyle(.orange).accessibilityIdentifier("statistics.noHandshake")
                            }
                            Text("采样：\(stats.sampledAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        } else { Text("连接后显示统计").foregroundStyle(.secondary) }
                    }
                    Section("当前验证范围") {
                        Text(controller.isSimulation ? "连接与流量均为模拟结果，用于验证界面和操作流程。" : "隧道启动和握手不代表全部流量已经验证安全。DNS、IPv6 和断线行为仍需实网测试。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("NPV")
                .toolbar {
                    #if DEBUG && targetEnvironment(simulator)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("开发场景") { showScenarios = true }.accessibilityIdentifier("simulation.scenarios")
                    }
                    #endif
                }
            }.tabItem { Label("连接", systemImage: "network") }.tag(0)

            NavigationStack {
                List {
                    modeBanner
                    Section(controller.isSimulation ? "实验身份" : "设备身份") {
                        if controller.publicKey.isEmpty {
                            Text("先生成身份，再填写服务器配置。").foregroundStyle(.secondary)
                            Button("生成设备密钥") { Task { await controller.generateIdentity() } }
                                .disabled(!canEdit || !controller.ready).accessibilityIdentifier("identity.generate")
                        } else {
                            Text(controller.isSimulation ? "实验公钥仅用于模拟，不登记到真实服务器。" : "将公钥登记到服务器。私钥保存在设备 Keychain 中。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(controller.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .accessibilityIdentifier("identity.publicKey")
                            if !controller.isSimulation { ShareLink("分享设备公钥", item: controller.publicKey) }
                        }
                    }
                    Section("服务器") {
                        if let profile = controller.profile {
                            LabeledContent("名称", value: profile.name)
                            LabeledContent("地址", value: profile.endpoint.wireGuardValue)
                            LabeledContent("IPv4", value: profile.ipv4Address)
                            LabeledContent("IPv6", value: profile.ipv6Address)
                            LabeledContent("DNS", value: profile.dnsServers.joined(separator: ", "))
                        } else { Text("尚未保存服务器").foregroundStyle(.secondary) }
                        Button(controller.profile == nil ? "添加服务器" : "编辑服务器") { showConfiguration = true }
                            .disabled(controller.identityID == nil || !controller.ready || !canEdit)
                            .accessibilityIdentifier("profile.edit")
                        Button("重新载入配置") { Task { await controller.bootstrap() } }
                            .disabled(controller.busy || controller.pendingAction != nil).accessibilityIdentifier("profile.reload")
                    }
                    messages
                }.navigationTitle("配置")
            }.tabItem { Label("配置", systemImage: "slider.horizontal.3") }.tag(1)

            NavigationStack {
                List {
                    modeBanner
                    Section("本次运行记录") {
                        if controller.activity.isEmpty { Text("暂无操作记录").foregroundStyle(.secondary) }
                        ForEach(controller.activity) { entry in
                            HStack {
                                Text(entry.kind.title)
                                Spacer()
                                Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        Text("保留最近 30 条操作记录，不记录密钥、配置内容或业务流量。退出 App 后清除。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle("诊断")
            }.tabItem { Label("诊断", systemImage: "list.bullet.rectangle") }.tag(2)
        }
        .sheet(isPresented: $showConfiguration) { ConfigurationView(controller: controller) }
        #if DEBUG && targetEnvironment(simulator)
        .sheet(isPresented: $showScenarios) { SimulationSettingsView(controller: controller) }
        #endif
    }
    private var canEdit: Bool { !controller.busy && controller.pendingAction == nil && controller.state.canEdit }
    @ViewBuilder private var modeBanner: some View {
        if controller.isSimulation {
            Section {
                Label("模拟模式 · 不接管网络", systemImage: "testtube.2")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange).accessibilityIdentifier("simulation.banner")
                Text("实验数据仅保留本次运行。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var messages: some View {
        if controller.busy { Section { ProgressView("正在处理配置…") } }
        if let message = controller.errorMessage {
            Section("需要处理") { Text(message).foregroundStyle(.red).accessibilityIdentifier("operation.error") }
        }
        if let notice = controller.notice {
            Section { Text(notice).font(.footnote).accessibilityIdentifier("operation.notice") }
        }
    }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }
}

private struct ConfigurationView: View {
    @ObservedObject var controller: TunnelController
    @Environment(\.dismiss) private var dismiss
    @State private var name = "实验服务器"
    @State private var host = ""
    @State private var port = "51820"
    @State private var serverPublicKey = ""
    @State private var ipv4 = "10.77.0.2/32"
    @State private var ipv6 = "fd77::2/128"
    @State private var dns = "10.77.0.1"
    @State private var validationError: String?
    @FocusState private var focus: Field?
    private enum Field: Hashable { case name, host, port, key, ipv4, ipv6, dns }

    var body: some View {
        NavigationStack {
            Form {
                if let error = validationError ?? controller.errorMessage {
                    Section("请检查") { Text(error).foregroundStyle(.red).accessibilityIdentifier("profile.error") }
                }
                #if DEBUG && targetEnvironment(simulator)
                Section {
                    Button("填入模拟示例") {
                        name = "模拟服务器"; host = "vpn.example.invalid"; port = "51820"
                        serverPublicKey = Data(repeating: 7, count: 32).base64EncodedString()
                        ipv4 = "10.77.0.2/32"; ipv6 = "fd77::2/128"; dns = "10.77.0.1"
                        validationError = nil; focus = nil
                    }.accessibilityIdentifier("profile.example")
                } footer: { Text("示例仅用于模拟模式，不能连接真实服务器。") }
                #endif
                Section("服务器参数") {
                    field("名称", text: $name, id: "profile.name", focus: .name)
                    field("服务器 IP 或域名", text: $host, id: "profile.host", focus: .host)
                    field("UDP 端口", text: $port, id: "profile.port", focus: .port).keyboardType(.numberPad)
                    field("服务器公钥", text: $serverPublicKey, id: "profile.key", focus: .key)
                }
                Section {
                    field("IPv4 / 前缀", text: $ipv4, id: "profile.ipv4", focus: .ipv4)
                    field("IPv6 / 前缀", text: $ipv6, id: "profile.ipv6", focus: .ipv6)
                    field("DNS IP，用逗号分隔", text: $dns, id: "profile.dns", focus: .dns)
                } header: { Text("分配给此设备的地址") }
                footer: { Text("IPv4、IPv6 和 DNS 必须与服务器配置一致。") }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("服务器配置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(controller.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(controller.busy || controller.pendingAction != nil || !controller.state.canEdit)
                        .accessibilityIdentifier("profile.save")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focus = nil } }
            }
            .onAppear {
                guard let p = controller.profile else { return }
                name = p.name; host = p.endpoint.host; port = String(p.endpoint.port)
                serverPublicKey = p.serverPublicKey; ipv4 = p.ipv4Address; ipv6 = p.ipv6Address
                dns = p.dnsServers.joined(separator: ", ")
            }
        }
    }
    private func field(_ title: String, text: Binding<String>, id: String, focus target: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).focused($focus, equals: target).accessibilityIdentifier(id)
        }
    }
    private func save() {
        validationError = nil
        guard let id = controller.identityID else { return }
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let portNumber = Int(trim(port)) else { reject(.invalidPort); return }
        let candidate = TunnelProfile(id: controller.profile?.id ?? UUID(), identityID: id, name: trim(name),
                                      endpoint: TunnelEndpoint(host: trim(host), port: portNumber),
                                      serverPublicKey: trim(serverPublicKey), ipv4Address: trim(ipv4), ipv6Address: trim(ipv6),
                                      dnsServers: dns.split(separator: ",", omittingEmptySubsequences: false).map { trim(String($0)) })
        do { try candidate.validate() }
        catch let error as ProfileError { reject(error); return }
        catch { validationError = "配置无效，请检查输入。"; return }
        focus = nil
        Task { if await controller.save(candidate) { dismiss() } }
    }
    private func reject(_ error: ProfileError) {
        validationError = error.localizedDescription
        switch error {
        case .invalidName: focus = .name
        case .invalidEndpoint: focus = .host
        case .invalidPort: focus = .port
        case .invalidPublicKey: focus = .key
        case .invalidIPv4: focus = .ipv4
        case .invalidIPv6: focus = .ipv6
        case .invalidDNS: focus = .dns
        default: focus = nil
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct SimulationSettingsView: View {
    @ObservedObject var controller: TunnelController
    @EnvironmentObject private var session: SimulationSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SimulationScenario.allCases) { scenario in
                        Button {
                            session.scenario = scenario
                            Task { await controller.bootstrap(); dismiss() }
                        } label: {
                            HStack { Text(scenario.title); Spacer(); if session.scenario == scenario { Image(systemName: "checkmark") } }
                        }
                        .disabled(!controller.state.canEdit || controller.busy || controller.pendingAction != nil)
                        .accessibilityIdentifier("scenario.\(scenario.rawValue)")
                    }
                } footer: { Text("请先断开连接再切换。超时场景使用与真机相同的 30 秒等待期限；恢复场景只模拟系统状态变化。") }
            }.navigationTitle("开发场景").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
#endif
