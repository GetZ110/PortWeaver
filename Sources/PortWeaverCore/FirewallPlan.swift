import Foundation

public enum FirewallPlan {
    public static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func allowAppCommands(bundlePath: String) throws -> String {
        guard bundlePath.hasPrefix("/"), bundlePath.hasSuffix(".app"),
              !bundlePath.contains("\n"), !bundlePath.contains("\r"), !bundlePath.contains("\0") else {
            throw RuleError.invalid("请从打包后的 PortWeaver.app 中配置防火墙。")
        }
        let path = shellQuote(bundlePath)
        // Do not change the global firewall state, block-all, PF, or existing app rules.
        return "\(tool) --add \(path) && \(tool) --unblockapp \(path)"
    }
    public static func appleScript(for command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
