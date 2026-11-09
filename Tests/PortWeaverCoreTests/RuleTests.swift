import XCTest
@testable import PortWeaverCore

final class RuleTests: XCTestCase {
    func testIPv6AndMixedFamiliesValidate() throws {
        for pair in [("::1", "127.0.0.1"), ("127.0.0.1", "::1"), ("::", "example.com"), ("2001:db8::1", "2001:db8::2")] {
            let rule = ForwardRule(name: "IPv6", listenHost: pair.0, listenPort: 8000, targetHost: pair.1, targetPort: 9000)
            XCTAssertNoThrow(try rule.validated())
        }
        XCTAssertEqual(ForwardRule.endpoint("::1", 8080), "[::1]:8080")
    }
    func testInvalidPortsAddressesAndLoopsAreRejected() {
        let cases: [ForwardRule] = [
            .init(name: "", targetHost: "localhost"),
            .init(name: "bad", listenPort: 0, targetHost: "localhost"),
            .init(name: "bad", targetHost: "localhost", targetPort: 65536),
            .init(name: "bad", listenHost: "localhost", targetHost: "localhost"),
            .init(name: "bad", targetHost: "http://localhost/path"),
            .init(name: "bad", targetHost: "::"),
            .init(name: "bad", targetHost: "999.999.1.2"),
            .init(name: "loop", listenHost: "::", listenPort: 9000, targetHost: "::1", targetPort: 9000),
            .init(name: "loop", listenPort: 9000, targetHost: "127.0.0.1", targetPort: 9000),
        ]
        for rule in cases { XCTAssertThrowsError(try rule.validated(), rule.name) }
    }
    func testAtomicStorageAndDuplicateIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rules.json")
        let rule = ForwardRule(name: "测试", transport: .udp, listenHost: "::1", listenPort: 9000,
                               targetHost: "127.0.0.1", targetPort: 9001, group: "DNS", note: "备注", startOnLaunch: true)
        try RuleStorage.save(RuleDocument(rules: [rule]), to: url)
        XCTAssertEqual(try RuleStorage.load(from: url).rules, [rule])
        XCTAssertThrowsError(try RuleDocument(rules: [rule, rule]).validated())
        var future = RuleDocument(rules: [rule]); future.version = 2
        XCTAssertThrowsError(try future.validated())
    }
    func testFirewallQuotesPathsWithoutExecutingTheirContent() throws {
        let path = "/Applications/O'Brien $(touch nope) `id`.app"
        let command = try FirewallPlan.allowAppCommands(bundlePath: path)
        XCTAssertTrue(command.contains("'\\''"))
        XCTAssertFalse(command.contains("--setglobalstate"))
        XCTAssertEqual(command.components(separatedBy: " && ").count, 2)
        let script = FirewallPlan.appleScript(for: command)
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertThrowsError(try FirewallPlan.allowAppCommands(bundlePath: "/tmp/app\ninject.app"))
        XCTAssertThrowsError(try FirewallPlan.allowAppCommands(bundlePath: "/tmp/binary"))
    }
}
