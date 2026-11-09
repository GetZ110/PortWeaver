import SwiftUI
import PortWeaverCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingDeletion: ForwardRule?
    @State private var sidebarVisible = true
    var body: some View {
        HSplitView {
            if sidebarVisible {
                sidebar.frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            Group {
                if store.destination == "firewall" { FirewallView() }
                else if store.destination == "activity" { ActivityView() }
                else if store.destination == "settings" { AppSettingsView(loginItem: store.loginItem) }
                else { rulesContent }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationTitle("PortWeaver")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { sidebarVisible.toggle() } label: {
                    Label("显示侧边栏", systemImage: "sidebar.left")
                }.help("显示或隐藏侧边栏")
            }
            ToolbarItemGroup {
                Button(action: store.newRule) { Label("新建规则", systemImage: "plus") }.help("新建转发规则 ⌘N")
                Menu {
                    Button("导入 JSON 规则…", action: store.importRules)
                    Button("导出全部规则…", action: store.exportRules)
                    Divider()
                    Button("添加示例规则（不启动）", action: store.addExamples)
                } label: { Label("配置", systemImage: "ellipsis.circle") }.help("导入、导出与示例")
                if !["firewall", "activity", "settings"].contains(store.destination) {
                    Divider()
                    Button { store.inspectorVisible.toggle() } label: {
                        Label("显示检查器", systemImage: "sidebar.right")
                    }.help("显示或隐藏规则详情")
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("删除这条规则？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { if let rule = pendingDeletion { store.delete(rule) }; pendingDeletion = nil }
        } message: { Text("将删除“\(pendingDeletion?.name ?? "")”并停止它的转发连接。") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.destination) {
                Section("规则") {
                    sidebarItem("全部规则", icon: "square.stack.3d.up", tag: "all", count: store.rules.count)
                    sidebarItem("正在转发", icon: "waveform.path", tag: "running", count: store.runningCount)
                }
                Section("协议") {
                    sidebarItem("TCP", icon: "arrow.left.arrow.right", tag: "tcp", count: store.rules.filter { $0.transport == .tcp }.count)
                    sidebarItem("UDP", icon: "point.3.connected.trianglepath.dotted", tag: "udp", count: store.rules.filter { $0.transport == .udp }.count)
                    sidebarItem("IPv6", icon: "network", tag: "ipv6", count: store.rules.filter(\.isIPv6).count)
                }
                Section("系统") {
                    Label("防火墙", systemImage: "checkmark.shield").tag("firewall")
                    Label("活动记录", systemImage: "clock.arrow.circlepath").tag("activity")
                    Label("通用设置", systemImage: "gearshape").tag("settings")
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 7) {
                Label(store.runningCount > 0 ? "转发引擎运行中" : "转发引擎待命", systemImage: store.runningCount > 0 ? "circle.inset.filled" : "circle")
                    .foregroundStyle(store.runningCount > 0 ? .green : .secondary)
                Text("关闭窗口后继续运行\n退出应用时停止转发")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func sidebarItem(_ title: String, icon: String, tag: String, count: Int) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }.tag(tag)
    }
    private var title: String {
        ["all": "全部规则", "running": "正在转发", "tcp": "TCP 规则", "udp": "UDP 规则", "ipv6": "IPv6 规则"][store.destination] ?? "全部规则"
    }
    private var rulesContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.title2.weight(.semibold))
                        Text("\(store.filteredRules.count) 条").foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("搜索名称、地址或分组", text: $store.search).textFieldStyle(.plain)
                            if !store.search.isEmpty {
                                Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                            }
                        }.padding(7).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 300)
                        Spacer(minLength: 8)
                        Button(action: store.startFiltered) { Image(systemName: "play.fill") }
                            .help("启动当前列表中的规则 ⌘R").accessibilityLabel("启动当前列表")
                            .disabled(store.filteredRules.isEmpty || store.filteredRules.allSatisfy { store.isActive($0.id) })
                        Button(action: store.stopAll) { Label("停止全部", systemImage: "stop.fill") }
                            .help("停止全部规则 ⌘.").accessibilityLabel("停止全部规则").disabled(store.activeCount == 0)
                    }
                }.padding(20)
                Divider()
                if store.rules.isEmpty {
                    ContentUnavailableView {
                        Label("让两个端口连接起来", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text("创建 TCP 或 UDP 转发规则。\n从本机回环地址开始，也可监听局域网与 IPv6。")
                    } actions: {
                        Button("新建规则", action: store.newRule).buttonStyle(.borderedProminent)
                        Button("导入配置…", action: store.importRules)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.filteredRules.isEmpty {
                    ContentUnavailableView("没有匹配的规则", systemImage: "line.3.horizontal.decrease", description: Text("尝试其他关键词或切换到全部规则。"))
                } else {
                    Table(store.filteredRules, selection: $store.selectedID) {
                        TableColumn("名称") { rule in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.name).fontWeight(.medium).lineLimit(1)
                                Text(rule.group.isEmpty ? rule.transport.rawValue : "\(rule.transport.rawValue) · \(rule.group)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 6)
                        }.width(min: 130, ideal: 170)
                        TableColumn("监听 → 目标") { rule in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.listenEndpoint).foregroundStyle(.primary)
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                                    Text(rule.targetEndpoint)
                                }.foregroundStyle(.secondary)
                            }.font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        }.width(min: 170, ideal: 210)
                        TableColumn("状态") { rule in
                            PhaseLabel(phase: store.snapshot(rule.id).phase)
                                .contextMenu { ruleMenu(rule) }
                        }.width(min: 90, ideal: 105)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first, let rule = store.rules.first(where: { $0.id == id }) { ruleMenu(rule) }
                    } primaryAction: { ids in
                        if let id = ids.first, let rule = store.rules.first(where: { $0.id == id }) { store.edit(rule) }
                    }
                    .onDeleteCommand { pendingDeletion = store.selectedRule }
                }
                Divider()
                HStack {
                    Label("\(store.runningCount) 条正在转发", systemImage: "circle.inset.filled").foregroundStyle(.secondary)
                    Spacer()
                    Text("TCP / UDP · IPv4 / IPv6").foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.inspectorVisible {
                Divider()
                Group {
                    if store.draft != nil { RuleEditor() }
                    else if let rule = store.selectedRule {
                        RuleInspector(rule: rule, delete: { pendingDeletion = rule })
                    } else {
                        ContentUnavailableView("选择一条规则", systemImage: "sidebar.right", description: Text("在这里查看转发详情，或新建一条规则。"))
                    }
                }.frame(width: 310).frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
    @ViewBuilder private func ruleMenu(_ rule: ForwardRule) -> some View {
        Button(store.isActive(rule.id) ? "停止转发" : "启动转发") { store.toggle(rule) }
        Button("编辑规则") { store.edit(rule) }.disabled(store.isActive(rule.id))
        Button("复制规则") { store.duplicate(rule) }
        Divider()
        Button("删除规则…", role: .destructive) { pendingDeletion = rule }
    }
}

struct PhaseLabel: View {
    let phase: ForwardPhase
    var color: Color {
        switch phase { case .running: return .green; case .starting: return .orange; case .failed: return .red; case .stopped: return .secondary }
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: phase == .running ? "circle.inset.filled" : phase == .starting ? "clock" : failure ? "exclamationmark.circle" : "circle")
                .font(.system(size: 10))
            Text(failure ? "失败" : phase.label).font(.caption)
        }.foregroundStyle(color).help(phase.label)
    }
    var failure: Bool { if case .failed = phase { return true }; return false }
}
