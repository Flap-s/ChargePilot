import Foundation

/// macOS's own charge limit (System Settings › Battery), driven through PowerUI's smart-charge client.
/// On recent firmware the SMC charge switches are reserved to Apple, but this limit (80–95 % in 5 % steps)
/// still stops charging while the Mac keeps running on the adapter.
public final class NativeChargeLimitController {
    private typealias MsgSend = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
    private typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
    private typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
    private typealias ObjectErrorFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias ByteErrorFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias WordErrorFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt64
    private typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool
    private typealias DisableFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

    private let client: AnyObject
    private let send: UnsafeMutableRawPointer

    /// Limits macOS accepts, ascending (100 means off). Empty when the Mac has no native limit.
    public let steps: [Int]

    public init?() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW) != nil,
              let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend"),
              let type: AnyClass = NSClassFromString("PowerUISmartChargeClient")
        else { return nil }
        self.send = send
        let required = ["initWithClientName:", "isMCLSupported", "availableChargeLimitsWithError:",
                        "getMCLLimitWithError:", "isMCLCurrentlyEnabled:", "setMCLLimit:error:", "disableMCL:"]
        guard required.allSatisfy({ class_getInstanceMethod(type, NSSelectorFromString($0)) != nil }),
              let raw = unsafeBitCast(send, to: AllocFn.self)(type, NSSelectorFromString("alloc")),
              let client = unsafeBitCast(send, to: InitFn.self)(raw, NSSelectorFromString("initWithClientName:"), "chargepilot")
        else { return nil }
        self.client = client
        guard unsafeBitCast(send, to: BoolFn.self)(client, NSSelectorFromString("isMCLSupported")) else { return nil }
        var error: NSError?
        let limits = unsafeBitCast(send, to: ObjectErrorFn.self)(client, NSSelectorFromString("availableChargeLimitsWithError:"), &error)
        let values = (limits as? [NSNumber])?.map(\.intValue).sorted() ?? []
        guard error == nil, !values.isEmpty else { return nil }
        steps = values
    }

    /// The active limit, or 100 when macOS charges fully.
    public func current() -> Int? {
        var error: NSError?
        let enabled = unsafeBitCast(send, to: WordErrorFn.self)(client, NSSelectorFromString("isMCLCurrentlyEnabled:"), &error)
        guard error == nil else { return nil }
        if enabled == 0 { return 100 }
        let limit = unsafeBitCast(send, to: ByteErrorFn.self)(client, NSSelectorFromString("getMCLLimitWithError:"), &error)
        return error == nil ? Int(limit) : nil
    }

    /// Sets the limit; 100 turns it off. Returns an error message on failure.
    public func set(_ limit: Int) -> String? {
        var error: NSError?
        let ok: Bool
        if limit >= 100 {
            ok = unsafeBitCast(send, to: DisableFn.self)(client, NSSelectorFromString("disableMCL:"), &error)
        } else {
            guard steps.contains(limit) else { return "macOS n'accepte pas une limite native de \(limit) %" }
            ok = unsafeBitCast(send, to: SetFn.self)(client, NSSelectorFromString("setMCLLimit:error:"), UInt8(limit), &error)
        }
        if let error { return "Limite macOS : \(error.localizedDescription)" }
        return ok ? nil : "macOS a refusé la limite de \(limit) %"
    }
}
