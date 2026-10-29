import Foundation

/// XPC interface of the privileged helper. Payloads travel as JSON to keep the interface small.
@objc public protocol ChargePilotHelperProtocol {
    /// Encoded `HelperState`. `fromApp` marks the menu bar app as running.
    func state(fromApp: Bool, reply: @escaping (Data) -> Void)
    /// Replaces the configuration with an encoded `ChargeConfig`. Replies with an error message or nil.
    func setConfig(_ data: Data, reply: @escaping (String?) -> Void)
    /// Runs a `HelperCommand`.
    func perform(_ command: String, value: Int, reply: @escaping (String?) -> Void)
    /// The app is quitting.
    func detachApp(reply: @escaping () -> Void)
    /// Diagnostics: reads any SMC key, replying "type size attributes hex" or an error.
    func smcRead(_ key: String, reply: @escaping (String) -> Void)
    /// Diagnostics: writes one of the charge-related SMC keys.
    func smcWrite(_ key: String, hex: String, reply: @escaping (String?) -> Void)
    /// Sets the SMC switches to use on firmware the built-in table doesn't cover (JSON, empty to reset).
    func setHardwareOverride(_ data: Data, reply: @escaping (String?) -> Void)
}

public enum HelperClientError: LocalizedError {
    case unreachable(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let message): return "Assistant injoignable : \(message)"
        case .refused(let message): return message
        }
    }
}

/// Talks to the helper over its Mach service.
public final class HelperClient: @unchecked Sendable {
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    public init() {}

    deinit { connection?.invalidate() }

    private func proxy(_ onError: @escaping (Error) -> Void) -> ChargePilotHelperProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: ChargePilotIDs.helperLabel, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: ChargePilotHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.connection = nil; self.lock.unlock()
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? ChargePilotHelperProtocol
    }

    /// Runs one call, resuming exactly once whether the helper replies or the connection fails.
    private func call<T>(_ body: @escaping (ChargePilotHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let fail: (Error) -> Void = { error in
                once.run { continuation.resume(throwing: HelperClientError.unreachable(error.localizedDescription)) }
            }
            guard let proxy = proxy(fail) else {
                fail(NSError(domain: "ChargePilot", code: 1))
                return
            }
            body(proxy) { value in once.run { continuation.resume(returning: value) } }
        }
    }

    public func state(fromApp: Bool = false) async throws -> HelperState {
        let data: Data = try await call { proxy, done in proxy.state(fromApp: fromApp, reply: done) }
        return try JSON.decoder.decode(HelperState.self, from: data)
    }

    public func setConfig(_ config: ChargeConfig) async throws {
        let data = try JSON.encoder.encode(config)
        let error: String? = try await call { proxy, done in proxy.setConfig(data, reply: done) }
        if let error { throw HelperClientError.refused(error) }
    }

    public func perform(_ command: HelperCommand, value: Int = 0) async throws {
        let error: String? = try await call { proxy, done in proxy.perform(command.rawValue, value: value, reply: done) }
        if let error { throw HelperClientError.refused(error) }
    }

    /// Tells the helper the app is quitting, waiting at most `timeout`. XPC replies arrive off the main thread,
    /// so this may block the main thread while the app terminates.
    public func detachAppSync(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        guard let proxy = proxy({ _ in done.signal() }) else { return }
        proxy.detachApp { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    public func smcRead(_ key: String) async throws -> String {
        try await call { proxy, done in proxy.smcRead(key, reply: done) }
    }

    public func smcWrite(_ key: String, hex: String) async throws {
        let error: String? = try await call { proxy, done in proxy.smcWrite(key, hex: hex, reply: done) }
        if let error { throw HelperClientError.refused(error) }
    }

    public func setHardwareOverride(_ json: Data) async throws {
        let error: String? = try await call { proxy, done in proxy.setHardwareOverride(json, reply: done) }
        if let error { throw HelperClientError.refused(error) }
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }
}

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
