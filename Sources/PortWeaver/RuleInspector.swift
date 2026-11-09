import SwiftUI
import PortWeaverCore

struct RuleInspector: View {
    @EnvironmentObject private var store: AppStore
    let rule: ForwardRule
    let delete: () -> Void
    private var snapshot: ForwardSnapshot { store.snapshot(rule.id) }
    private func bytes(_ count: UInt64) -> String {
        count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("规则详情").font(.headline)
                        Spacer()
                        Button { store.edit(rule) } label: { Image(systemName: "pencil") }
                            .disabled(store.isActive(rule.id)).help(store.isActive(rule.id) ? "编辑前请停止转发" : "编辑规则").accessibilityLabel("编辑规则")
                    }
                    Text(rule.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    PhaseLabel(phase: snapshot.phase)
                }
                VStack(alignment: .leading, spacing: 14) {
                    endpoint("监听地址", host: rule.listenHost, port: rule.listenPort)
                    Image(systemName: "arrow.down").foregroundStyle(.tertiary).padding(.leading, 3)
                    endpoint("转发目标", host: rule.targetHost, port: rule.targetPort)
                }
                Button { store.toggle(rule) } label: {
                    Label(store.isActive(rule.id) ? "停止转发" : "启动转发", systemImage: store.isActive(rule.id) ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                VStack(spacing: 12) {
                    detail("传输协议", value: rule.transport.rawValue)
                    detail("监听 / 目标", value: "\(rule.listensOnIPv6 ? "IPv6" : "IPv4") → \(rule.targetHost.contains(":") ? "IPv6" : ForwardRule.isIPAddress(rule.targetHost) ? "IPv4" : "DNS")")
                    detail("分组", value: rule.group.isEmpty ? "未分组" : rule.group)
                    detail("打开应用时启动", value: rule.startOnLaunch ? "开启" : "关闭")
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("本次运行").font(.headline)
                    detail(rule.transport == .udp ? "UDP 会话" : "TCP 连接", value: snapshot.sessions.formatted())
                    detail("发送至目标", value: bytes(snapshot.uploaded))
                    detail("从目标接收", value: bytes(snapshot.downloaded))
                    Text(rule.transport == .udp ? "UDP 会话空闲 60 秒后回收；每条规则最多 512 个会话。" : "最多 256 个并发连接。目标连接超时为 15 秒。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = snapshot.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if case let .failed(error) = snapshot.phase {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if !rule.note.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("备注").font(.headline)
                        Text(rule.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Divider()
                HStack {
                    Button("复制规则") { store.duplicate(rule) }
                    Spacer()
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }.help("删除规则").accessibilityLabel("删除规则")
                }
            }.padding(20)
        }
    }
    private func endpoint(_ title: String, host: String, port: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ForwardRule.endpoint(host, port)).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func detail(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(.callout)
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var nameFocused: Bool
    @State private var listenPortText = ""
    @State private var targetPortText = ""
    private func binding<Value>(_ keyPath: WritableKeyPath<ForwardRule, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { store.draft?[keyPath: keyPath] ?? fallback }, set: { store.draft?[keyPath: keyPath] = $0 })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.draftIsNew ? "新建规则" : "编辑规则").font(.headline)
                Spacer()
                Button { store.cancelEdit() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("取消编辑")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    field("名称") {
                        TextField("例如：本地开发服务", text: binding(\.name, fallback: "")).focused($nameFocused)
                    }
                    field("传输协议") {
                        Picker("传输协议", selection: binding(\.transport, fallback: .tcp)) {
                            ForEach(Transport.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    field("监听地址") {
                        TextField("127.0.0.1 或 ::1", text: binding(\.listenHost, fallback: ""))
                            .font(.system(.body, design: .monospaced))
                        Menu("快速选择监听范围") {
                            Button("IPv4 · 仅本机（127.0.0.1）") { store.draft?.listenHost = "127.0.0.1" }
                            Button("IPv4 · 全部接口（0.0.0.0）") { store.draft?.listenHost = "0.0.0.0" }
                            Button("IPv6 · 仅本机（::1）") { store.draft?.listenHost = "::1" }
                            Button("IPv6 · 全部接口（::）") { store.draft?.listenHost = "::" }
                        }.font(.caption)
                        if ["0.0.0.0", "::"].contains(store.draft?.listenHost ?? "") {
                            Text("全部接口允许其他设备访问此端口。请确认目标服务适合共享。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    field("监听端口") {
                        TextField("1–65535", text: $listenPortText).onChange(of: listenPortText) { _, value in store.draft?.listenPort = Int(value) ?? 0 }
                    }
                    Divider()
                    field("目标地址") {
                        TextField("IP 地址或主机名", text: binding(\.targetHost, fallback: ""))
                            .font(.system(.body, design: .monospaced))
                        Text("IPv6 直接填写 ::1 等地址，无需方括号。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    field("目标端口") {
                        TextField("1–65535", text: $targetPortText).onChange(of: targetPortText) { _, value in store.draft?.targetPort = Int(value) ?? 0 }
                    }
                    field("分组") { TextField("可选", text: binding(\.group, fallback: "")) }
                    field("备注") {
                        TextField("可选", text: binding(\.note, fallback: ""), axis: .vertical).lineLimit(2...4)
                    }
                    Toggle("打开应用时自动启动此规则", isOn: binding(\.startOnLaunch, fallback: false)).font(.callout)
                    Text("规则保存在此 Mac。退出应用将停止转发；关闭窗口仍会继续运行。")
                        .font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(20)
            }
            Divider()
            if let error = store.draftError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12)
                    .accessibilityLabel("保存失败：\(error)")
            }
            HStack {
                Button("取消", action: store.cancelEdit).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存规则", action: store.saveDraft).buttonStyle(.borderedProminent).keyboardShortcut("s")
            }.padding(16)
        }
        .onAppear { syncPorts(); nameFocused = true }
        .onChange(of: store.draft?.id) { _, _ in syncPorts() }
    }
    private func syncPorts() {
        listenPortText = store.draft.map { String($0.listenPort) } ?? ""
        targetPortText = store.draft.map { String($0.targetPort) } ?? ""
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }
}
