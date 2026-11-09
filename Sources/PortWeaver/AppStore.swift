import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PortWeaverCore

struct ActivityEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
    let isError: Bool
}

@MainActor
final class AppStore: ObservableObject {
    @Published var rules: [ForwardRule] = []
    @Published var snapshots: [UUID: ForwardSnapshot] = [:]
    @Published var selectedID: UUID?
    @Published var destination = "all"
    @Published var search = ""
    @Published var errorMessage: String?
    @Published var activity: [ActivityEntry] = []
    @Published var firewall = FirewallStatus()
    @Published var firewallBusy = false
    @Published var firewallMessage: String?
    @Published var firewallMessageIsError = false
    @Published var inspectorVisible = true
    @Published var draft: ForwardRule?
    @Published var draftIsNew = false
    @Published var draftError: String?
    private var initialized = false
    private var persistenceAvailable = true
    private let preview = ProcessInfo.processInfo.arguments.contains("--preview")
    private lazy var engine = ForwardingEngine { [weak self] id, snapshot in
        Task { @MainActor in self?.receive(id, snapshot) }
    }
    let loginItem = LoginItemService()
    let configURL: URL

    init() {
        configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortWeaver/rules.json")
        if preview {
            rules = Self.examples
            selectedID = rules.first?.id
            return
        }
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                rules = try RuleStorage.load(from: configURL).rules
            }
        } catch {
            persistenceAvailable = false
            errorMessage = "无法读取规则文件，已保留原文件。请修复或移走 \(configURL.path) 后重新启动。\n\(error.localizedDescription)"
        }
    }

    func initialize() {
        guard !initialized else { return }; initialized = true
        if !preview { for rule in rules where rule.startOnLaunch { start(rule) } }
        Task { await refreshFirewall() }
    }

    var filteredRules: [ForwardRule] {
        rules.filter { rule in
            let scope: Bool
            switch destination {
            case "running": scope = isActive(rule.id)
            case "tcp": scope = rule.transport == .tcp
            case "udp": scope = rule.transport == .udp
            case "ipv6": scope = rule.isIPv6
            default: scope = true
            }
            let text = [rule.name, rule.listenEndpoint, rule.targetEndpoint, rule.group, rule.note].joined(separator: " ")
            return scope && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }
    }
    var selectedRule: ForwardRule? { rules.first { $0.id == selectedID } }
    var activeCount: Int { rules.filter { isActive($0.id) }.count }
    var runningCount: Int { rules.filter { snapshot($0.id).phase == .running }.count }
    func snapshot(_ id: UUID) -> ForwardSnapshot { snapshots[id] ?? ForwardSnapshot() }
    func isActive(_ id: UUID) -> Bool {
        let phase = snapshot(id).phase
        return phase == .running || phase == .starting
    }

    func start(_ rule: ForwardRule) {
        guard !preview else { errorMessage = "界面预览模式不会建立监听。请正常启动应用。"; return }
        guard !isActive(rule.id) else { return }
        snapshots[rule.id] = ForwardSnapshot()
        snapshots[rule.id]?.phase = .starting
        engine.stop(rule.id) // Also disposes a previously failed listener before retrying.
        engine.start(rule)
        log("启动 \(rule.name) · \(rule.transport.rawValue) \(rule.listenEndpoint) → \(rule.targetEndpoint)")
    }
    func stop(_ rule: ForwardRule) {
        engine.stop(rule.id)
        snapshots[rule.id] = ForwardSnapshot()
        log("停止 \(rule.name)")
    }
    func toggle(_ rule: ForwardRule) { isActive(rule.id) ? stop(rule) : start(rule) }
    func startFiltered() { for rule in filteredRules where !isActive(rule.id) { start(rule) } }
    func stopAll() { engine.stopAll(); for id in snapshots.keys { snapshots[id] = ForwardSnapshot() }; log("停止全部转发") }
    func shutdown() { engine.shutdown() }

    func receive(_ id: UUID, _ snapshot: ForwardSnapshot) {
        guard rules.contains(where: { $0.id == id }) else { return }
        let previous = snapshots[id]
        snapshots[id] = snapshot
        if snapshot.phase == .running && previous?.phase != .running { log("监听已就绪 · \(rules.first { $0.id == id }?.name ?? "")") }
        if let error = snapshot.lastError, error != previous?.lastError { log(error, isError: true) }
        if case let .failed(message) = snapshot.phase, previous?.phase != snapshot.phase {
            log("监听失败：\(message)", isError: true)
        }
    }

    func newRule() {
        guard discardDraftIfNeeded() else { return }
        draft = ForwardRule(name: "新建转发", targetHost: "127.0.0.1", targetPort: 3000)
        draftIsNew = true; draftError = nil; inspectorVisible = true
        if ["firewall", "activity", "settings"].contains(destination) { destination = "all" }
    }
    func edit(_ rule: ForwardRule) {
        guard !isActive(rule.id), discardDraftIfNeeded() else { return }
        selectedID = rule.id; draft = rule; draftIsNew = false; draftError = nil; inspectorVisible = true
    }
    func duplicate(_ rule: ForwardRule) {
        guard discardDraftIfNeeded() else { return }
        var copy = rule; copy.id = UUID(); copy.name += " 副本"; copy.startOnLaunch = false
        if copy.listenPort < 65535 { copy.listenPort += 1 }
        draft = copy; draftIsNew = true; draftError = nil; inspectorVisible = true
    }
    private func discardDraftIfNeeded() -> Bool {
        guard let draft else { return true }
        if !draftIsNew, rules.first(where: { $0.id == draft.id }) == draft { return true }
        let alert = NSAlert()
        alert.messageText = "放弃尚未保存的编辑？"
        alert.informativeText = "当前规则的修改尚未保存。放弃后将打开另一条规则。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func cancelEdit() { draft = nil; draftError = nil }
    func saveDraft() {
        guard let draft else { return }
        do {
            let checked = try draft.validated()
            guard !isActive(checked.id) else { throw RuleError.invalid("请先停止此规则再修改。") }
            var next = rules
            if let index = next.firstIndex(where: { $0.id == checked.id }) { next[index] = checked }
            else { next.append(checked) }
            try persist(next)
            rules = next; selectedID = checked.id; cancelEdit()
            log("保存规则 · \(checked.name)")
        } catch { draftError = error.localizedDescription }
    }
    func delete(_ rule: ForwardRule) {
        do {
            let next = rules.filter { $0.id != rule.id }; try persist(next)
            stop(rule); rules = next; snapshots.removeValue(forKey: rule.id)
            if selectedID == rule.id { selectedID = next.first?.id }
            if draft?.id == rule.id { cancelEdit() }
            log("删除规则 · \(rule.name)")
        } catch { errorMessage = error.localizedDescription }
    }
    func addExamples() {
        do {
            let samples = Self.examples
            try persist(rules + samples); rules += samples; selectedID = samples.first?.id
            log("已添加示例规则（未启动）")
        } catch { errorMessage = error.localizedDescription }
    }
    private func persist(_ next: [ForwardRule]) throws {
        guard !preview else { return }
        guard persistenceAvailable else { throw RuleError.invalid("原配置读取失败，已禁止覆盖。请先修复配置文件并重新启动。") }
        try RuleStorage.save(RuleDocument(rules: next), to: configURL)
    }
    func importRules() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try RuleStorage.load(from: url)
            var imported = document.rules
            // Treat imported rules as copies and never start them without a local decision.
            for index in imported.indices { imported[index].id = UUID(); imported[index].startOnLaunch = false }
            try persist(rules + imported); rules += imported
            if let first = imported.first { selectedID = first.id }
            log("已导入 \(imported.count) 条规则（未启动）")
        } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
    }
    func exportRules() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "PortWeaver-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try RuleStorage.save(RuleDocument(rules: rules), to: url); log("已导出 \(rules.count) 条规则") }
        catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }
    func log(_ message: String, isError: Bool = false) {
        activity.insert(ActivityEntry(message: message, isError: isError), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
    }
    func refreshFirewall() async {
        guard !firewallBusy else { return }; firewallBusy = true
        firewall = await FirewallService.inspect(bundlePath: Bundle.main.bundleURL.path)
        firewallBusy = false
    }
    func configureFirewall() async {
        guard !firewallBusy else { return }; firewallBusy = true
        firewallMessage = nil
        do {
            try await FirewallService.configure(bundlePath: Bundle.main.bundleURL.path)
            firewall = await FirewallService.inspect(bundlePath: Bundle.main.bundleURL.path)
            firewallMessageIsError = firewall.app != "允许入站连接"
            firewallMessage = firewallMessageIsError ? "配置命令已执行，但系统尚未确认允许入站。请检查下方状态。" : "已将 PortWeaver 加入防火墙并允许入站连接。"
            log(firewallMessage!, isError: firewallMessageIsError)
        } catch {
            firewallMessageIsError = true; firewallMessage = error.localizedDescription
            log(error.localizedDescription, isError: true)
        }
        firewallBusy = false
    }
    static var examples: [ForwardRule] {
        [ForwardRule(name: "本地开发服务", listenPort: 8080, targetHost: "127.0.0.1", targetPort: 3000, group: "开发", note: "示例：将本机 8080 转发到开发服务 3000；请先确认目标服务已运行。"),
         ForwardRule(name: "UDP 回显", transport: .udp, listenPort: 5354, targetHost: "127.0.0.1", targetPort: 5355, group: "测试", note: "示例：需要先在本机 5355 启动 UDP 回显服务。"),
         ForwardRule(name: "IPv6 本地服务", listenHost: "::1", listenPort: 8081, targetHost: "::1", targetPort: 3001, group: "开发", note: "示例：IPv6 回环地址，仅本机可访问。")]
    }
}
