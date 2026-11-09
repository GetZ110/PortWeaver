import Foundation
import Network
import Darwin

public enum Transport: String, Codable, CaseIterable, Identifiable, Sendable {
    case tcp = "TCP", udp = "UDP"
    public var id: String { rawValue }
}

public struct ForwardRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: Transport
    public var listenHost: String
    public var listenPort: Int
    public var targetHost: String
    public var targetPort: Int
    public var group: String
    public var note: String
    public var startOnLaunch: Bool

    public init(id: UUID = UUID(), name: String = "", transport: Transport = .tcp,
                listenHost: String = "127.0.0.1", listenPort: Int = 8080,
                targetHost: String = "", targetPort: Int = 80,
                group: String = "", note: String = "", startOnLaunch: Bool = false) {
        self.id = id; self.name = name; self.transport = transport
        self.listenHost = listenHost; self.listenPort = listenPort
        self.targetHost = targetHost; self.targetPort = targetPort
        self.group = group; self.note = note; self.startOnLaunch = startOnLaunch
    }

    public var listenEndpoint: String { Self.endpoint(listenHost, listenPort) }
    public var targetEndpoint: String { Self.endpoint(targetHost, targetPort) }
    public var isIPv6: Bool { listenHost.contains(":") || targetHost.contains(":") }
    public var listensOnIPv6: Bool { listenHost.contains(":") }
    public static func endpoint(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public func validated() throws -> ForwardRule {
        var rule = self
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.listenHost = listenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.targetHost = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.name.isEmpty else { throw RuleError.invalid("请填写规则名称。") }
        guard (1...65535).contains(listenPort), (1...65535).contains(targetPort) else {
            throw RuleError.invalid("端口必须是 1 到 65535 之间的整数。")
        }
        guard Self.isIPAddress(rule.listenHost) else {
            throw RuleError.invalid("监听地址必须是 IPv4 或 IPv6 地址，例如 127.0.0.1、0.0.0.0 或 ::1。")
        }
        guard Self.isTargetHost(rule.targetHost) else {
            throw RuleError.invalid("目标必须是 IP 地址或有效主机名；请勿填写协议、端口或 URL 路径。")
        }
        if Self.isUnspecified(rule.targetHost) {
            throw RuleError.invalid("目标不能是 0.0.0.0 或 ::；请填写实际服务地址。")
        }
        // Prevent the common self-loop, including wildcard listeners reaching loopback.
        if listenPort == targetPort {
            let localTargets = ["localhost", "127.0.0.1", "::1"]
            if rule.listenHost.lowercased() == rule.targetHost.lowercased()
                || (Self.isUnspecified(rule.listenHost) && localTargets.contains(rule.targetHost.lowercased())) {
                throw RuleError.invalid("监听端与目标端指向同一端口，可能形成转发循环。请选择不同的目标。")
            }
        }
        return rule
    }

    public static func isIPAddress(_ host: String) -> Bool {
        // Network.framework accepts interface-scoped IPv6 literals, e.g. fe80::1%en0.
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    private static func isTargetHost(_ host: String) -> Bool {
        if isIPAddress(host) { return true }
        guard !host.isEmpty, host.count <= 253, !host.contains(":"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let value = host.hasSuffix(".") ? String(host.dropLast()) : host
        // Reject malformed dotted IPv4 rather than handing it to DNS.
        if value.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }

    private static func isUnspecified(_ host: String) -> Bool {
        if let v4 = IPv4Address(host) { return v4 == IPv4Address.any }
        if let v6 = IPv6Address(host) { return v6 == IPv6Address.any }
        return false
    }
}

public enum RuleError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public struct RuleDocument: Codable, Sendable {
    public var version: Int = 1
    public var rules: [ForwardRule]
    public init(rules: [ForwardRule]) { self.rules = rules }

    public func validated() throws -> RuleDocument {
        guard version == 1 else { throw RuleError.invalid("不支持此配置版本（\(version)）。") }
        guard rules.count <= 2000 else { throw RuleError.invalid("配置最多可包含 2000 条规则。") }
        guard Set(rules.map(\.id)).count == rules.count else { throw RuleError.invalid("配置中存在重复的规则 ID。") }
        return RuleDocument(rules: try rules.map { try $0.validated() })
    }
}

public enum RuleStorage {
    public static func load(from url: URL) throws -> RuleDocument {
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw RuleError.invalid("配置文件超过 4 MB。") }
        return try JSONDecoder().decode(RuleDocument.self, from: data).validated()
    }
    public static func save(_ document: RuleDocument, to url: URL) throws {
        let checked = try document.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(checked)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
