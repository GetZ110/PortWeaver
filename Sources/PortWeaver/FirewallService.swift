import AppKit
import PortWeaverCore

struct FirewallStatus: Sendable {
    var global = "尚未检查"
    var app = "尚未检查"
    var blocksAll = false
    var detail = ""
}

enum FirewallService {
    static func inspect(bundlePath: String) async -> FirewallStatus {
        await Task.detached(priority: .utility) {
            let global = run(["--getglobalstate"])
            let blocked = run(["--getblockall"])
            let app = run(["--getappblocked", bundlePath])
            var status = FirewallStatus()
            if global.output.contains("State = 0") { status.global = "已关闭" }
            else if global.output.contains("State = 1") || global.output.contains("State = 2") { status.global = "已开启" }
            else { status.global = "无法确定" }
            status.blocksAll = blocked.output.contains("ENABLED")
            let lower = app.output.lowercased()
            // “not blocked” contains “blocked”; test the allow condition first.
            if app.code == 0 && lower.contains("not blocked") { status.app = "允许入站连接" }
            else if lower.contains("not part") || lower.contains("not found") { status.app = "尚未登记" }
            else if app.code == 0 && lower.contains("blocked") { status.app = "已阻止入站连接" }
            else { status.app = "无法确定" }
            status.detail = [global.output, blocked.output, app.output].joined(separator: "\n")
            return status
        }.value
    }

    static func configure(bundlePath: String) async throws {
        guard FileManager.default.fileExists(atPath: bundlePath), Bundle.main.bundleURL.pathExtension == "app" else {
            throw RuleError.invalid("请运行 build/PortWeaver.app 后再配置防火墙。")
        }
        let command = try FirewallPlan.allowAppCommands(bundlePath: bundlePath)
        let script = FirewallPlan.appleScript(for: command)
        let result = await Task.detached(priority: .userInitiated) {
            runExecutable("/usr/bin/osascript", arguments: ["-e", script])
        }.value
        guard result.code == 0 else {
            if result.output.contains("-128") { throw RuleError.invalid("已取消管理员授权，未完成防火墙配置。") }
            throw RuleError.invalid("防火墙配置失败：\(result.output)")
        }
    }

    private static func run(_ arguments: [String]) -> (code: Int32, output: String) {
        runExecutable(FirewallPlan.tool, arguments: arguments)
    }
    private static func runExecutable(_ path: String, arguments: [String]) -> (code: Int32, output: String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { return (-1, error.localizedDescription) }
    }
}
