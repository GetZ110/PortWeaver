import Foundation
import ServiceManagement
import AppKit

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var errorMessage: String?
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var description: String {
        switch status {
        case .enabled: return "已开启，登录此 Mac 后自动运行"
        case .requiresApproval: return "等待批准，请在系统登录项设置中允许"
        case .notRegistered: return "已关闭"
        case .notFound: return "无法找到应用，请从固定路径运行 .app"
        @unknown default: return "状态未知"
        }
    }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ value: Bool) {
        do {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                throw NSError(domain: "PortWeaver", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先运行打包后的 PortWeaver.app，再设置登录时启动。"])
            }
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
            if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { errorMessage = error.localizedDescription; refresh() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
