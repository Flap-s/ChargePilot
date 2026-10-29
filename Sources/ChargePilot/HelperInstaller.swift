import AppKit
import CryptoKit
import Foundation
import ChargePilotCore

/// Installs the privileged helper as a launchd daemon, with one administrator prompt.
enum HelperInstaller {
    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(ChargePilotIDs.helperLabel)")
    }

    static var bundledPlist: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(ChargePilotIDs.helperLabel).plist")
    }

    static var bundledCLI: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/chargepilot")
    }

    static let cliLink = "/usr/local/bin/chargepilot"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: ChargePilotIDs.helperPath)
            && FileManager.default.fileExists(atPath: ChargePilotIDs.helperPlistPath)
    }

    /// The installed helper differs from the one in this app (the app was updated).
    static var needsUpdate: Bool {
        guard isInstalled, let bundled = digest(bundledHelper) else { return false }
        return digest(URL(fileURLWithPath: ChargePilotIDs.helperPath)) != bundled
    }

    static var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink)) == bundledCLI.path
    }

    private static func digest(_ url: URL) -> SHA256Digest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
    }

    static func install() throws {
        guard FileManager.default.fileExists(atPath: bundledHelper.path) else {
            throw InstallError("L'assistant est introuvable dans l'application. Lancez ChargePilot depuis son paquet .app.")
        }
        let label = ChargePilotIDs.helperLabel
        let support = ChargePilotIDs.helperSupportDirectory
        try runAsAdmin("""
        \(legacyCleanup)
        if [ -d \(quote(legacySupport)) ] && [ ! -d \(quote(support)) ]; then /bin/mv \(quote(legacySupport)) \(quote(support)); fi
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/mkdir -p /Library/PrivilegedHelperTools
        /bin/cp -f \(quote(bundledHelper.path)) \(quote(ChargePilotIDs.helperPath))
        /usr/sbin/chown root:wheel \(quote(ChargePilotIDs.helperPath))
        /bin/chmod 755 \(quote(ChargePilotIDs.helperPath))
        /bin/cp -f \(quote(bundledPlist.path)) \(quote(ChargePilotIDs.helperPlistPath))
        /usr/sbin/chown root:wheel \(quote(ChargePilotIDs.helperPlistPath))
        /bin/chmod 644 \(quote(ChargePilotIDs.helperPlistPath))
        /bin/launchctl enable system/\(label)
        /bin/launchctl bootstrap system \(quote(ChargePilotIDs.helperPlistPath)) 2>/dev/null || { /bin/sleep 1; /bin/launchctl bootstrap system \(quote(ChargePilotIDs.helperPlistPath)); }
        """)
    }

    static func uninstall() throws {
        try runAsAdmin("""
        \(legacyCleanup)
        /bin/launchctl bootout system/\(ChargePilotIDs.helperLabel) 2>/dev/null || true
        /bin/rm -f \(quote(ChargePilotIDs.helperPath)) \(quote(ChargePilotIDs.helperPlistPath))
        if [ -L \(quote(cliLink)) ]; then /bin/rm -f \(quote(cliLink)); fi
        """)
    }

    static func installCLI() throws {
        try runAsAdmin("""
        /bin/mkdir -p /usr/local/bin
        /bin/ln -sf \(quote(bundledCLI.path)) \(quote(cliLink))
        """)
    }

    static func uninstallCLI() throws {
        try runAsAdmin("if [ -L \(quote(cliLink)) ]; then /bin/rm -f \(quote(cliLink)); fi")
    }

    // MARK: Migration from Mesure

    /// The app's former name: its helper is stopped (it hands charging back first) and its settings carried over.
    private static let legacyLabel = "app.mesure.helper"
    private static let legacySupport = "/Library/Application Support/Mesure"

    private static var legacyCleanup: String {
        """
        /bin/launchctl bootout system/\(legacyLabel) 2>/dev/null || true
        /bin/rm -f /Library/PrivilegedHelperTools/\(legacyLabel) /Library/LaunchDaemons/\(legacyLabel).plist
        if [ -L /usr/local/bin/mesure ]; then /bin/rm -f /usr/local/bin/mesure; fi
        """
    }

    // MARK: Helpers

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAsAdmin(_ script: String) throws {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"ChargePilot doit installer son assistant pour contrôler la charge.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -128 { throw InstallError("Installation annulée.") }
            throw InstallError(error[NSAppleScript.errorMessage] as? String ?? "Échec de l'installation.")
        }
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
