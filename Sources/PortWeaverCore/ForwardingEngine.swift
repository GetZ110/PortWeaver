import Foundation
import Network

public enum ForwardPhase: Equatable, Sendable {
    case stopped, starting, running, failed(String)
    public var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "正在启动"
        case .running: return "转发中"
        case .failed: return "启动或转发失败"
        }
    }
}

public struct ForwardSnapshot: Sendable {
    public var phase: ForwardPhase = .stopped
    public var sessions = 0
    public var uploaded: UInt64 = 0
    public var downloaded: UInt64 = 0
    public var lastError: String?
    public init() {}
}

/// Every listener, connection, timer and counter is confined to one serial queue.
/// Callbacks arrive on that queue; a GUI should hop to MainActor.
public final class ForwardingEngine: @unchecked Sendable {
    public typealias Observer = @Sendable (UUID, ForwardSnapshot) -> Void
    private let queue = DispatchQueue(label: "app.portweaver.forwarding", qos: .userInitiated)
    private var forwards: [UUID: Forwarder] = [:]
    private let observer: Observer
    public init(observer: @escaping Observer) { self.observer = observer }

    public func start(_ rule: ForwardRule) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.forwards[rule.id] == nil else { return }
            do {
                let checked = try rule.validated()
                let observer = self.observer
                let forwarder = try Forwarder(rule: checked, queue: self.queue) { snapshot in
                    observer(rule.id, snapshot)
                }
                self.forwards[rule.id] = forwarder
                forwarder.start()
            } catch {
                var snapshot = ForwardSnapshot(); snapshot.phase = .failed(error.localizedDescription)
                self.observer(rule.id, snapshot)
            }
        }
    }

    public func stop(_ id: UUID) {
        queue.async {
            self.forwards.removeValue(forKey: id)?.stop()
            self.observer(id, ForwardSnapshot())
        }
    }

    public func stopAll() {
        queue.async {
            for (id, forwarder) in self.forwards {
                forwarder.stop(); self.observer(id, ForwardSnapshot())
            }
            self.forwards.removeAll()
        }
    }

    /// Synchronous shutdown is used when the application terminates.
    public func shutdown() {
        queue.sync {
            for forwarder in forwards.values { forwarder.stop() }
            forwards.removeAll()
        }
    }
}

private final class Forwarder {
    let rule: ForwardRule
    let queue: DispatchQueue
    let listener: NWListener
    var sessions: [UUID: RelaySession] = [:]
    var snapshot = ForwardSnapshot()
    let observer: (ForwardSnapshot) -> Void
    var timer: DispatchSourceTimer?
    var stopped = false

    init(rule: ForwardRule, queue: DispatchQueue, observer: @escaping (ForwardSnapshot) -> Void) throws {
        self.rule = rule; self.queue = queue; self.observer = observer
        let parameters: NWParameters
        if rule.transport == .tcp {
            let tcp = NWProtocolTCP.Options(); tcp.enableKeepalive = true
            parameters = NWParameters(tls: nil, tcp: tcp)
        } else {
            parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        }
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = rule.listensOnIPv6 ? .v6 : .v4
        }
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(rule.listenHost), port: NWEndpoint.Port(rawValue: UInt16(rule.listenPort))!)
        // Exclusive bind: a collision must fail, not split traffic between rules.
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }

    func start() {
        snapshot.phase = .starting; observer(snapshot)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready: self.snapshot.phase = .running
            case .failed(let error):
                self.snapshot.phase = .failed(error.localizedDescription)
                self.snapshot.lastError = error.localizedDescription
                self.closeResources()
            case .waiting(let error):
                self.snapshot.phase = .starting
                self.snapshot.lastError = error.localizedDescription
            default: return
            }
            self.observer(self.snapshot)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            let cap = self.rule.transport == .tcp ? 256 : 512
            guard self.sessions.count < cap else {
                connection.cancel()
                self.snapshot.lastError = "已达到此规则的并发上限（\(cap)）。"
                self.observer(self.snapshot); return
            }
            let session = RelaySession(inbound: connection, rule: self.rule, queue: self.queue)
            session.onBytes = { [weak self] up, down in
                self?.snapshot.uploaded &+= UInt64(up)
                self?.snapshot.downloaded &+= UInt64(down)
            }
            session.onClose = { [weak self, weak session] error in
                guard let self, let session else { return }
                self.sessions.removeValue(forKey: session.id)
                self.snapshot.sessions = self.sessions.count
                if let error { self.snapshot.lastError = error }
                self.observer(self.snapshot)
            }
            self.sessions[session.id] = session
            self.snapshot.sessions = self.sessions.count
            self.observer(self.snapshot)
            session.start()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            // UDP peers have distinct target sockets, keeping client responses isolated.
            // Reclaim idle UDP associations after 60 seconds. TCP connect timeout: 15s.
            for session in Array(self.sessions.values) { session.expireIfNeeded(now: now) }
            self.snapshot.sessions = self.sessions.count
            self.observer(self.snapshot)
        }
        self.timer = timer; timer.resume()
        listener.start(queue: queue)
    }

    func closeResources() {
        listener.cancel()
        timer?.cancel(); timer = nil
        for session in Array(sessions.values) { session.close() }
        sessions.removeAll(); snapshot.sessions = 0
    }
    func stop() { stopped = true; closeResources() }
}

private final class RelaySession {
    let id = UUID()
    let inbound: NWConnection
    let outbound: NWConnection
    let rule: ForwardRule
    let queue: DispatchQueue
    var onBytes: ((Int, Int) -> Void)?
    var onClose: ((String?) -> Void)?
    var closed = false
    var inboundReady = false
    var outboundReady = false
    var relaying = false
    var finishedDirections = 0
    var lastActivity = DispatchTime.now().uptimeNanoseconds
    let created = DispatchTime.now().uptimeNanoseconds

    init(inbound: NWConnection, rule: ForwardRule, queue: DispatchQueue) {
        self.inbound = inbound; self.rule = rule; self.queue = queue
        let parameters: NWParameters = rule.transport == .tcp ? .tcp : .udp
        outbound = NWConnection(host: NWEndpoint.Host(rule.targetHost),
                                port: NWEndpoint.Port(rawValue: UInt16(rule.targetPort))!, using: parameters)
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in self?.stateChanged(state, incoming: true) }
        outbound.stateUpdateHandler = { [weak self] state in self?.stateChanged(state, incoming: false) }
        inbound.start(queue: queue); outbound.start(queue: queue)
    }

    func stateChanged(_ state: NWConnection.State, incoming: Bool) {
        guard !closed else { return }
        switch state {
        case .ready:
            if incoming { inboundReady = true } else { outboundReady = true }
            if inboundReady && outboundReady && !relaying {
                relaying = true
                pump(from: inbound, to: outbound, upload: true)
                pump(from: outbound, to: inbound, upload: false)
            }
        case .failed(let error):
            // A receive already in flight can still carry buffered bytes. Drain it
            // before ending the session, including on a transport state failure.
            if !relaying { close(error.localizedDescription) }
        default: break
        }
    }

    func pump(from source: NWConnection, to destination: NWConnection, upload: Bool) {
        guard !closed else { return }
        if rule.transport == .udp {
            source.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.closed else { return }
                if let error { self.close(error.localizedDescription); return }
                // Empty datagrams are valid and must retain their message boundary.
                let payload = data ?? Data()
                self.lastActivity = DispatchTime.now().uptimeNanoseconds
                destination.send(content: payload, contentContext: .defaultMessage, isComplete: true,
                                 completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if let error { self.close(error.localizedDescription); return }
                    self.record(payload.count, upload: upload)
                    self.pump(from: source, to: destination, upload: upload)
                })
            }
        } else {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, context, isComplete, error in
                let complete = isComplete && (context?.isFinal == true)
                guard let self, !self.closed else { return }
                self.lastActivity = DispatchTime.now().uptimeNanoseconds
                if let data, !data.isEmpty {
                    // Wait for each write before the next read: bounded memory + backpressure.
                    destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        guard let self, !self.closed else { return }
                        if let sendError { self.close(sendError.localizedDescription); return }
                        self.record(data.count, upload: upload)
                        if let error { self.close(error.localizedDescription) }
                        else if complete { self.finish(destination) }
                        else { self.pump(from: source, to: destination, upload: upload) }
                    })
                } else if let error { self.close(error.localizedDescription) }
                else if complete { self.finish(destination) }
                else { self.pump(from: source, to: destination, upload: upload) }
            }
        }
    }

    func finish(_ destination: NWConnection) {
        // Forward FIN without closing the reverse stream (request/response half-close).
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                         completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error { self.close(error.localizedDescription); return }
            self.finishedDirections += 1
            if self.finishedDirections == 2 {
                // NWConnection.cancel() is asynchronous. Retain both connections
                // until their graceful cancellation has drained outstanding TCP data.
                self.gracefulClose()
            }
        })
    }

    func gracefulClose() {
        guard !closed else { return }; closed = true
        let retention = ConnectionDrain(inbound, outbound)
        retention.start { [weak self] in
            guard let self else { return }
            let callback = self.onClose; self.onClose = nil; self.onBytes = nil
            callback?(nil)
        }
    }

    func record(_ count: Int, upload: Bool) {
        lastActivity = DispatchTime.now().uptimeNanoseconds
        onBytes?(upload ? count : 0, upload ? 0 : count)
    }

    func expireIfNeeded(now: UInt64) {
        if !relaying && now - created > 15_000_000_000 { close("连接目标超时（15 秒）。") }
        else if rule.transport == .udp && now - lastActivity > 60_000_000_000 { close() }
    }

    func close(_ error: String? = nil) {
        guard !closed else { return }
        closed = true
        inbound.stateUpdateHandler = nil; outbound.stateUpdateHandler = nil
        inbound.cancel(); outbound.cancel()
        let callback = onClose; onClose = nil; onBytes = nil
        callback?(error)
    }
}


/// Holds connections until cancellation completion, rather than deallocating them
/// while the transport still has bytes queued for the receiving peer.
private final class ConnectionDrain {
    let inbound: NWConnection
    let outbound: NWConnection
    var remaining = 2
    var completion: (() -> Void)?
    init(_ inbound: NWConnection, _ outbound: NWConnection) {
        self.inbound = inbound; self.outbound = outbound
    }
    func start(completion: @escaping () -> Void) {
        self.completion = completion
        let handler: (NWConnection.State) -> Void = { [self] state in
            if case .cancelled = state {
                remaining -= 1
                if remaining == 0 {
                    inbound.stateUpdateHandler = nil; outbound.stateUpdateHandler = nil
                    self.completion?(); self.completion = nil
                }
            }
        }
        inbound.stateUpdateHandler = handler; outbound.stateUpdateHandler = handler
        inbound.cancel(); outbound.cancel()
    }
}
