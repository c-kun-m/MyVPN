import SwiftUI
import NPVCore

struct ConnectionView: View {
    @ObservedObject var controller: TunnelController
    @State private var showConfiguration = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(controller.state.label, systemImage: controller.state == .connected ? "network" : "network.slash")
                        .font(.title3.weight(.semibold))
                    Text(controller.profile?.name ?? "尚未添加测试服务器")
                    Text("第一阶段实验版本。隧道启动及握手状态不等于所有业务已验证可用。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let action = controller.pendingAction {
                        Text(action == .connect ? "连接请求已发送，等待系统确认。" : "断开请求已发送，等待系统确认。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if controller.state.canStop || controller.pendingAction == .connect {
                        Button("断开连接", role: .destructive) { controller.disconnect() }.disabled(controller.busy)
                    } else {
                        Button("连接服务器") { Task { await controller.connect() } }
                            .disabled(!controller.ready || controller.busy || controller.pendingAction != nil || controller.profile == nil || !controller.state.canEdit)
                    }
                    if controller.busy { ProgressView("正在处理系统配置…") }
                } header: { Text("连接") }

                if let message = controller.errorMessage {
                    Section("需要处理") { Text(message).foregroundStyle(.red) }
                }
                if let notice = controller.notice { Section { Text(notice).font(.footnote) } }

                Section("设备身份") {
                    if controller.publicKey.isEmpty {
                        Button("生成设备密钥") { Task { await controller.generateIdentity() } }
                            .disabled(controller.busy || !controller.ready || controller.pendingAction != nil || !controller.state.canEdit)
                    } else {
                        Text("将下方公钥登记到服务器。私钥仅保存在本机 Keychain。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(controller.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        ShareLink("分享设备公钥", item: controller.publicKey)
                    }
                }

                Section("服务器") {
                    if let profile = controller.profile {
                        LabeledContent("地址", value: profile.endpoint.wireGuardValue)
                        LabeledContent("本机 IPv4", value: profile.ipv4Address)
                        LabeledContent("本机 IPv6", value: profile.ipv6Address)
                    }
                    Button(controller.profile == nil ? "填写服务器配置" : "编辑服务器配置") { showConfiguration = true }
                        .disabled(controller.identityID == nil || controller.busy || !controller.ready || controller.pendingAction != nil || !controller.state.canEdit)
                    Button("重新载入系统配置") { Task { await controller.bootstrap() } }.disabled(controller.busy || controller.pendingAction != nil)
                }

                Section("隧道统计") {
                    if let stats = controller.stats {
                        LabeledContent("接收", value: bytes(stats.receivedBytes))
                        LabeledContent("发送", value: bytes(stats.sentBytes))
                        if let timestamp = stats.lastHandshakeUnixSeconds {
                            LabeledContent("最近成功握手") { Text(Date(timeIntervalSince1970: Double(timestamp)), style: .time) }
                        } else { Text("尚未观察到成功握手。请产生测试流量并检查服务器授权。") }
                        Text("采样时间：\(stats.sampledAt.formatted(date: .omitted, time: .standard))").font(.caption)
                    } else { Text("暂无实时统计").foregroundStyle(.secondary) }
                }
                Section("保护范围") {
                    Text("配置包含 IPv4／IPv6 默认路由及指定 DNS。系统保留部分必要服务例外。此版本尚需真机抓包验证断线及网络切换行为。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NPV 实验客户端")
            .sheet(isPresented: $showConfiguration) { ConfigurationView(controller: controller) }
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

    var body: some View {
        NavigationStack {
            Form {
                Section("测试服务器") {
                    TextField("名称", text: $name)
                    TextField("服务器 IP 或域名", text: $host).keyboardType(.URL)
                    TextField("UDP 端口", text: $port).keyboardType(.numberPad)
                    TextField("服务器公钥", text: $serverPublicKey)
                }
                Section("服务器分配给本机的地址") {
                    TextField("IPv4 / 前缀", text: $ipv4)
                    TextField("IPv6 / 前缀", text: $ipv6)
                    TextField("DNS IP，多个用逗号分隔", text: $dns)
                    Text("示例地址须与服务器实际配置一致。此阶段要求同时配置 IPv4 和 IPv6；DNS 服务器须能通过隧道访问。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = validationError ?? controller.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("服务器配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(controller.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(controller.busy || controller.pendingAction != nil || !controller.state.canEdit)
                }
            }
            .onAppear {
                guard let p = controller.profile else { return }
                name = p.name; host = p.endpoint.host; port = String(p.endpoint.port)
                serverPublicKey = p.serverPublicKey; ipv4 = p.ipv4Address; ipv6 = p.ipv6Address
                dns = p.dnsServers.joined(separator: ", ")
            }
        }
    }
    private func save() {
        validationError = nil
        guard let id = controller.identityID else { return }
        guard let portNumber = Int(port) else { validationError = ProfileError.invalidPort.localizedDescription; return }
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidate = TunnelProfile(id: controller.profile?.id ?? UUID(), identityID: id, name: trim(name),
                                      endpoint: TunnelEndpoint(host: trim(host), port: portNumber),
                                      serverPublicKey: trim(serverPublicKey), ipv4Address: trim(ipv4), ipv6Address: trim(ipv6),
                                      dnsServers: dns.split(separator: ",", omittingEmptySubsequences: false).map { trim(String($0)) })
        do { try candidate.validate() } catch { validationError = error.localizedDescription; return }
        Task { await controller.save(candidate); if controller.errorMessage == nil { dismiss() } }
    }
}
