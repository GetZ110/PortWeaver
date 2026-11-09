import SwiftUI
import AppKit

struct FirewallView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("防火墙", systemImage: "checkmark.shield").font(.title2.weight(.semibold))
                    Text("允许转发端口接收入站连接")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("macOS 应用防火墙按应用授权。配置后，PortWeaver 的 TCP 与 UDP 监听可接收入站连接；IPv4 和 IPv6 共用此授权。")
                        .foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    row("系统防火墙", value: store.firewall.global)
                    Divider()
                    row("PortWeaver 入站权限", value: store.firewall.app)
                    Divider()
                    row("阻止所有传入连接", value: store.firewall.blocksAll ? "已开启" : "未开启或未确认")
                }.padding(.horizontal, 16).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            Task { await store.configureFirewall() }
                        } label: {
                            Label(store.firewallBusy ? "正在处理…" : "自动配置防火墙…", systemImage: "lock.shield")
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.firewallBusy)
                        Button("刷新状态") { Task { await store.refreshFirewall() } }.disabled(store.firewallBusy)
                        if store.firewallBusy { ProgressView().controlSize(.small) }
                    }
                    Text("系统将请求管理员授权。仅登记并允许当前应用，不会更改全局防火墙开关。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = store.firewallMessage {
                        Label(message, systemImage: store.firewallMessageIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(store.firewallMessageIsError ? .red : .green).font(.callout).textSelection(.enabled)
                    }
                }
                if store.firewall.blocksAll {
                    Label("系统当前阻止所有传入连接，应用放行可能仍无法生效。请在系统设置中调整此策略。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("配置范围").font(.headline)
                    Text("此操作使用系统 socketfilterfw 工具，将当前 .app 路径加入允许列表。应用移动或重新签名后，可能需要重新配置。")
                    Text("路由器端口映射、PF 规则、VPN 与企业设备管理策略需要分别配置。防火墙放行不会将 127.0.0.1 或 ::1 变为局域网监听地址。")
                    Button("打开系统防火墙设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall") { NSWorkspace.shared.open(url) }
                    }
                }.foregroundStyle(.secondary).font(.callout)
                DisclosureGroup("系统检查原始结果") {
                    Text(store.firewall.detail.isEmpty ? "尚无结果" : store.firewall.detail)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.callout)
                Spacer(minLength: 0)
            }.frame(maxWidth: 650, alignment: .leading).padding(36).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func row(_ name: String, value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value).foregroundStyle(.secondary) }.padding(.vertical, 14)
    }
}

struct ActivityView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("活动记录").font(.title2.weight(.semibold))
                Spacer()
                Button("清空") { store.activity.removeAll() }.disabled(store.activity.isEmpty)
            }.padding(24)
            Divider()
            if store.activity.isEmpty {
                ContentUnavailableView("还没有活动记录", systemImage: "clock.arrow.circlepath", description: Text("规则启停、连接错误与防火墙操作会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.activity) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.isError ? "exclamationmark.circle" : "circle.fill")
                            .font(.system(size: entry.isError ? 13 : 6)).frame(width: 16, height: 18)
                            .foregroundStyle(entry.isError ? .red : .secondary)
                        Text(entry.time, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.message).textSelection(.enabled)
                    }.font(.callout).padding(.vertical, 6)
                }.listStyle(.inset)
            }
            Divider()
            Text("仅保留本次运行中最近 300 条记录，不记录转发内容。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var loginItem: LoginItemService
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("通用设置").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录时自动启动 PortWeaver", isOn: Binding(
                        get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                        .font(.headline).toggleStyle(.switch).accessibilityIdentifier("settings.login-at-launch")
                    Text(loginItem.description).foregroundStyle(.secondary)
                    Text("在登录当前用户后启动应用。若要自动恢复转发，请在需要的规则中勾选“打开应用时自动启动此规则”。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("打开系统登录项设置", action: loginItem.openSettings)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("状态栏与快捷操作").font(.headline)
                    Text("状态栏中可逐条启停规则，或启动全部、停止全部。关闭主窗口后应用继续运行，退出时停止全部转发。")
                        .font(.callout).foregroundStyle(.secondary)
                    shortcut("新建规则", keys: "⌘ N")
                    shortcut("启动当前列表", keys: "⌘ R")
                    shortcut("切换选中规则", keys: "⇧ ⌘ R")
                    shortcut("停止全部转发", keys: "⌘ .")
                    shortcut("打开设置", keys: "⌘ ,")
                    Text("键盘快捷键在 PortWeaver 位于前台时有效；状态栏开关可随时访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("规则文件").font(.headline)
                    Text(store.configURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.configURL]) }
                }
                Text("PortWeaver 1.0 · macOS 原生端口转发")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 620, alignment: .leading).padding(36).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { loginItem.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { loginItem.refresh() } }
        .alert("登录项设置未完成", isPresented: Binding(get: { loginItem.errorMessage != nil }, set: { if !$0 { loginItem.errorMessage = nil } })) {
            Button("好", role: .cancel) { loginItem.errorMessage = nil }
        } message: { Text(loginItem.errorMessage ?? "") }
    }
    private func shortcut(_ title: String, keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).foregroundStyle(.secondary) }.font(.callout)
    }
}
