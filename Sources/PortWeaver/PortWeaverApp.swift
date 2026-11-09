import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.activeCount > 0 else { store?.shutdown(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "停止转发并退出？"
        alert.informativeText = "当前有 \(store.activeCount) 条规则正在运行。退出 PortWeaver 会关闭监听和现有连接。"
        alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        store.shutdown(); return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
}

@main
struct PortWeaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("PortWeaver", id: "main") {
            ContentView().environmentObject(store)
                .frame(minWidth: 1060, minHeight: 660)
                .task { delegate.store = store; store.initialize() }
        }
        .defaultSize(width: 1220, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.destination = "settings"; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("新建规则") { store.newRule() }.keyboardShortcut("n")
                Button("导入规则…") { store.importRules() }.keyboardShortcut("o")
                Button("导出规则…") { store.exportRules() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("转发") {
                Button("启动当前列表") { store.startFiltered() }.keyboardShortcut("r")
                Button("切换选中规则") { if let rule = store.selectedRule { store.toggle(rule) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.selectedRule == nil)
                Button("停止全部") { store.stopAll() }.keyboardShortcut(".")
                Divider()
                Button("防火墙设置") { store.destination = "firewall"; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
        }
        MenuBarExtra("PortWeaver", systemImage: "arrow.left.arrow.right") {
            StatusMenu().environmentObject(store)
        }.menuBarExtraStyle(.window)
    }
}

struct StatusMenu: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.blue)
                Text("PortWeaver").font(.headline)
                Spacer()
                Text("\(store.runningCount) 条运行中").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            if store.rules.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有转发规则").font(.headline)
                    Text("打开主窗口，创建 TCP 或 UDP 规则。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("新建规则") { store.newRule(); showMainWindow() }
                        .buttonStyle(.borderedProminent)
                }.padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.rules) { rule in
                            HStack(alignment: .center, spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(rule.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text("\(rule.transport.rawValue) · \(rule.listenEndpoint)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    PhaseLabel(phase: store.snapshot(rule.id).phase)
                                }
                                Spacer(minLength: 0)
                                Toggle("启停 \(rule.name)", isOn: Binding(
                                    get: { store.isActive(rule.id) },
                                    set: { enabled in enabled ? store.start(rule) : store.stop(rule) }))
                                    .labelsHidden().toggleStyle(.switch).tint(.blue).controlSize(.regular)
                                    .help(store.isActive(rule.id) ? "停止 \(rule.name)" : "启动 \(rule.name)")
                            }.padding(.horizontal, 16).padding(.vertical, 12)
                            if rule.id != store.rules.last?.id { Divider().padding(.horizontal, 16) }
                        }
                    }
                }.frame(height: min(CGFloat(store.rules.count) * 88, 400))
                Divider()
                HStack {
                    Button { for rule in store.rules { store.start(rule) } } label: {
                        Label("启动全部", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.disabled(store.rules.allSatisfy { store.isActive($0.id) })
                    Button(action: store.stopAll) {
                        Label("停止全部", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.disabled(store.activeCount == 0)
                }.buttonStyle(.bordered).padding(12)
            }
            Divider()
            HStack {
                Button("打开主窗口") { showMainWindow() }.accessibilityIdentifier("status.open-main")
                Spacer()
                Button { store.destination = "settings"; showMainWindow() } label: {
                    Image(systemName: "gearshape")
                }.help("登录与启动设置").accessibilityLabel("打开设置").accessibilityIdentifier("status.open-settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("退出 PortWeaver").accessibilityLabel("退出 PortWeaver")
            }.buttonStyle(.borderless).padding(14)
        }.frame(width: 360)
    }
    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
