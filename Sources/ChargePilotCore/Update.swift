import Foundation

/// A dotted numeric version ("1.2.3", "v1.2"), compared component by component.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Ignore pre-release / build suffixes ("1.2.0-beta").
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The subset of GitHub's release payload the updater needs.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let browserDownloadUrl: URL
        public let size: Int
    }

    public static let archiveName = "ChargePilot.zip"

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlUrl: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    public var version: AppVersion? { AppVersion(tagName) }

    /// The zipped app: `ChargePilot.zip`, or any zip whose name starts with "ChargePilot".
    public var appArchive: Asset? {
        assets.first { $0.name == Self.archiveName }
            ?? assets.first { $0.name.hasPrefix("ChargePilot") && $0.name.hasSuffix(".zip") }
    }

    /// Builds a release from the page `github.com/<repo>/releases/latest` redirects to
    /// (`…/releases/tag/<tag>`). Used when the rate-limited API is unavailable.
    public static func fromLatestPage(_ url: URL, repository: String) -> GitHubRelease? {
        let parts = url.pathComponents
        guard let index = parts.lastIndex(of: "tag"), index + 1 < parts.count else { return nil }
        let tag = parts[index + 1]
        guard AppVersion(tag) != nil,
              let download = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(archiveName)") else { return nil }
        return GitHubRelease(tagName: tag, name: nil, body: nil, htmlUrl: url, draft: false, prerelease: false,
                             assets: [Asset(name: archiveName, browserDownloadUrl: download, size: 0)])
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// Whether this release should replace `current`.
    public func isUpdate(from current: AppVersion) -> Bool {
        guard let version, !draft, !prerelease, appArchive != nil else { return false }
        return version > current
    }
}

public enum UpdateError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// File-level steps of an update, kept free of UI so they can be tested.
public enum UpdateInstaller {
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) a échoué : \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// Unzips the archive (preserving the code signature) and returns the app inside it.
    public static func extractApp(from archive: URL, into directory: URL) throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let apps = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.message("L'archive de mise à jour ne contient pas exactement une application.") }
        return apps[0]
    }

    /// The downloaded app must be ChargePilot, at the advertised version, with an intact signature.
    public static func validate(app: URL, bundleIdentifier: String, version: AppVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.message("L'application téléchargée n'a pas d'Info.plist.")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.message("L'application téléchargée n'est pas ChargePilot.")
        }
        guard let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), shipped == version else {
            throw UpdateError.message("La version de l'application téléchargée ne correspond pas à la publication.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=identifier \"\(bundleIdentifier)\"", app.path])
    }

    /// Waits for `pid` to exit, swaps `current` for `new` (restoring the old app on failure),
    /// deletes `cleanUp`, then optionally relaunches. Runs detached so it outlives the app.
    public static func replaceAfterExit(pid: Int32, current: URL, with new: URL, relaunch: Bool, cleanUp: URL? = nil) throws {
        let script = """
        pid="$1"; current="$2"; new="$3"; relaunch="$4"; cleanup="$5"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="$(mktemp -d)/previous.app"
        if mv "$current" "$backup"; then
          if mv "$new" "$current"; then
            rm -rf "$backup"
          else
            mv "$backup" "$current"
          fi
        fi
        xattr -dr com.apple.quarantine "$current" 2>/dev/null
        [ -n "$cleanup" ] && rm -rf "$cleanup"
        [ "$relaunch" = 1 ] && open "$current"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "chargepilot-update", String(pid), current.path, new.path, relaunch ? "1" : "0",
                             cleanUp?.path ?? ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
