import Foundation
import ChargePilotCore

/// Exposes the daemon over XPC to the signed app and command-line tool.
final class Service: NSObject, NSXPCListenerDelegate, ChargePilotHelperProtocol {
    let daemon: Daemon

    init(daemon: Daemon) { self.daemon = daemon }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(
            "identifier \"\(ChargePilotIDs.appBundle)\" or identifier \"\(ChargePilotIDs.cliIdentifier)\""
        )
        connection.exportedInterface = NSXPCInterface(with: ChargePilotHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func state(fromApp: Bool, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            reply((try? JSON.encoder.encode(self.daemon.currentState(fromApp: fromApp))) ?? Data())
        }
    }

    func setConfig(_ data: Data, reply: @escaping (String?) -> Void) {
        guard let config = try? JSON.decoder.decode(ChargeConfig.self, from: data) else { return reply("Réglages illisibles") }
        DispatchQueue.main.async {
            self.daemon.setConfig(config)
            reply(nil)
        }
    }

    func perform(_ command: String, value: Int, reply: @escaping (String?) -> Void) {
        guard let command = HelperCommand(rawValue: command) else { return reply("Commande inconnue : \(command)") }
        DispatchQueue.main.async { reply(self.daemon.perform(command, value: value)) }
    }

    func detachApp(reply: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.daemon.detachApp()
            reply()
        }
    }

    func smcRead(_ key: String, reply: @escaping (String) -> Void) {
        DispatchQueue.main.async { reply(self.daemon.smcRead(key)) }
    }

    func smcWrite(_ key: String, hex: String, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { reply(self.daemon.smcWrite(key, hex: hex)) }
    }

    func setHardwareOverride(_ data: Data, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { reply(self.daemon.setHardwareOverride(data)) }
    }
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("L'assistant ChargePilot doit tourner en root (launchd).\n".utf8))
    exit(1)
}

let smc: SMC
do { smc = try SMC() } catch {
    log.error("SMC unavailable: \(String(describing: error), privacy: .public)")
    exit(1)
}

let daemon = Daemon(hardware: ChargeHardware(smc: smc))
let service = Service(daemon: daemon)
let listener = NSXPCListener(machServiceName: ChargePilotIDs.helperLabel)
listener.delegate = service
listener.resume()

// Hand charging back to macOS when launchd stops the helper (uninstall, update).
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    daemon.shutdown()
    exit(0)
}
termination.resume()

daemon.start()
RunLoop.main.run()
