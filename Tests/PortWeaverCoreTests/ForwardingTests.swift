import XCTest
import Darwin
@testable import PortWeaverCore

private struct SocketFailure: Error, CustomStringConvertible {
    let operation: String
    let code: Int32
    init(_ operation: String) { self.operation = operation; code = errno }
    var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

private func createSocket(ipv6: Bool, udp: Bool) throws -> Int32 {
    let fd = Darwin.socket(ipv6 ? AF_INET6 : AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketFailure("socket") }
    var timeout = timeval(tv_sec: 4, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    if ipv6 { var only: Int32 = 1; setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size)) }
    var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

private func withAddress<T>(ipv6: Bool, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
    if ipv6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian; address.sin6_addr = in6addr_loopback
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

private func bindEphemeral(_ fd: Int32, ipv6: Bool) throws -> UInt16 {
    guard withAddress(ipv6: ipv6, port: 0, { Darwin.bind(fd, $0, $1) }) == 0 else { throw SocketFailure("bind") }
    var address = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    guard withUnsafeMutablePointer(to: &address, { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }) == 0 else { throw SocketFailure("getsockname") }
    return withUnsafePointer(to: &address) { ptr in
        if ipv6 { return ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        return ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
    }
}

private func unusedPort(ipv6: Bool, udp: Bool) throws -> UInt16 {
    let fd = try createSocket(ipv6: ipv6, udp: udp); defer { Darwin.close(fd) }
    return try bindEphemeral(fd, ipv6: ipv6)
}

private final class EchoServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    let udp: Bool
    let halfClose: Bool
    let done = DispatchGroup()
    let lock = NSLock()
    var cancelled = false
    init(ipv6: Bool, udp: Bool, halfClose: Bool = false) throws {
        self.udp = udp; self.halfClose = halfClose
        fd = try createSocket(ipv6: ipv6, udp: udp)
        port = try bindEphemeral(fd, ipv6: ipv6)
        if !udp && Darwin.listen(fd, 16) != 0 { throw SocketFailure("listen") }
        done.enter()
        DispatchQueue.global().async { [self] in loop(); done.leave() }
    }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func loop() {
        while !isCancelled() {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            if udp {
                var buffer = [UInt8](repeating: 0, count: 65535)
                var peer = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &peer) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
                }
                if count >= 0 {
                    _ = withUnsafePointer(to: &peer) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer, count, 0, $0, length) }
                    }
                }
            } else {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { continue }
                var timeout = timeval(tv_sec: 4, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var buffer = [UInt8](repeating: 0, count: 65536)
                var accumulated = Data()
                while !isCancelled() {
                    let count = Darwin.recv(client, &buffer, buffer.count, 0)
                    if count <= 0 {
                        if halfClose && count == 0 { sendAll(client, data: accumulated) }
                        break
                    }
                    let payload = Data(buffer.prefix(count))
                    if halfClose { accumulated.append(payload) } else { sendAll(client, data: payload) }
                }
                Darwin.close(client)
            }
        }
    }
    func stop() {
        lock.lock(); cancelled = true; lock.unlock()
        _ = done.wait(timeout: .now() + 6)
        Darwin.close(fd)
    }
}

@discardableResult private func sendAll(_ fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            if count <= 0 { return false }; offset += count
        }
        return true
    }
}

final class ForwardingTests: XCTestCase {
    private func readyEngine(rule: ForwardRule) async throws -> ForwardingEngine {
        let ready = expectation(description: "listener ready")
        ready.assertForOverFulfill = false
        let engine = ForwardingEngine { id, snapshot in
            if id == rule.id && snapshot.phase == .running { ready.fulfill() }
        }
        engine.start(rule)
        await fulfillment(of: [ready], timeout: 6)
        return engine
    }
    private func exchange(ipv6: Bool, udp: Bool, port: UInt16, payload: Data, halfClose: Bool = false) throws -> Data {
        let fd = try createSocket(ipv6: ipv6, udp: udp); defer { Darwin.close(fd) }
        guard withAddress(ipv6: ipv6, port: port, { Darwin.connect(fd, $0, $1) }) == 0 else { throw SocketFailure("connect") }
        if udp {
            let count = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard count == payload.count else { throw SocketFailure("send datagram") }
        } else {
            guard sendAll(fd, data: payload) else { throw SocketFailure("send") }
            if halfClose { Darwin.shutdown(fd, SHUT_WR) }
        }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 65535)
        repeat {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            guard count >= 0 else { throw SocketFailure("recv") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            if udp { break }
        } while result.count < payload.count
        return result
    }
    func testTCPAndUDPAllFourAddressFamilyCombinations() async throws {
        for udp in [false, true] {
            for listenV6 in [false, true] {
                for targetV6 in [false, true] {
                    let echo = try EchoServer(ipv6: targetV6, udp: udp)
                    let port = try unusedPort(ipv6: listenV6, udp: udp)
                    let rule = ForwardRule(name: "matrix", transport: udp ? .udp : .tcp,
                                           listenHost: listenV6 ? "::1" : "127.0.0.1", listenPort: Int(port),
                                           targetHost: targetV6 ? "::1" : "127.0.0.1", targetPort: Int(echo.port))
                    let engine = try await readyEngine(rule: rule)
                    let payload = Data("\(rule.transport) \(rule.listenHost) → \(rule.targetHost) 中文🚀".utf8)
                    do {
                        let received = try exchange(ipv6: listenV6, udp: udp, port: port, payload: payload)
                        XCTAssertEqual(received, payload, "\(udp) \(listenV6) → \(targetV6)")
                        if udp {
                            // A distinct local socket must receive its own payload.
                            let other = Data("other-peer".utf8)
                            XCTAssertEqual(try exchange(ipv6: listenV6, udp: true, port: port, payload: other), other)
                            // Zero-length datagrams must also traverse the relay.
                            XCTAssertEqual(try exchange(ipv6: listenV6, udp: true, port: port, payload: Data()), Data())
                        }
                    } catch { engine.shutdown(); echo.stop(); throw error }
                    engine.shutdown(); echo.stop()
                }
            }
        }
    }
    func testTCPLargeStreamAndHalfClose() async throws {
        let echo = try EchoServer(ipv6: false, udp: false, halfClose: true)
        defer { echo.stop() }
        let port = try unusedPort(ipv6: false, udp: false)
        let rule = ForwardRule(name: "half-close", listenPort: Int(port), targetHost: "127.0.0.1", targetPort: Int(echo.port))
        let engine = try await readyEngine(rule: rule); defer { engine.shutdown() }
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        XCTAssertEqual(try exchange(ipv6: false, udp: false, port: port, payload: payload, halfClose: true), payload)
    }
    func testPortCollisionReportsFailureAndStopReleasesPort() async throws {
        let occupied = try EchoServer(ipv6: false, udp: false); defer { occupied.stop() }
        let failed = expectation(description: "collision fails"); failed.assertForOverFulfill = false
        let engine = ForwardingEngine { _, snapshot in if case .failed = snapshot.phase { failed.fulfill() } }
        let rule = ForwardRule(name: "collision", listenPort: Int(occupied.port), targetHost: "127.0.0.1", targetPort: 9)
        engine.start(rule)
        await fulfillment(of: [failed], timeout: 6)
        engine.shutdown()
        let port = try unusedPort(ipv6: true, udp: true)
        let next = ForwardRule(name: "release", transport: .udp, listenHost: "::1", listenPort: Int(port), targetHost: "::1", targetPort: 9)
        let nextEngine = try await readyEngine(rule: next)
        nextEngine.shutdown()
        // Network cancellation finishes asynchronously; retry the real bind briefly.
        var released = false
        for _ in 0..<30 {
            let fd = try createSocket(ipv6: true, udp: true)
            released = withAddress(ipv6: true, port: port, { Darwin.bind(fd, $0, $1) }) == 0
            Darwin.close(fd)
            if released { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(released)
    }
}
