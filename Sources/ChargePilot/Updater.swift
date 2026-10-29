import AppKit
import ChargePilotCore
import UserNotifications

/// Checks GitHub Releases for a newer ChargePilot and installs it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading
        case installing
        case failed(String)
    }

    private enum Key {
        static let lastCheck = "lastUpdateCheck"
        static let announced = "announcedUpdate"
        static let automatic = "autoCheckUpdates"
        static let repository = "updateRepository"
        /// Test hook: a URL (https or file) serving a GitHub release JSON, used instead of GitHub.
        static let feed = "updateFeedURL"
        /// Set before relaunching into an update, so the new version can refresh the helper right away.
        static let justUpdated = "justUpdated"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// "owner/repo" written into Info.plist by the build script from the git remote.
    let builtInRepository = (Bundle.main.object(forInfoDictionaryKey: "ChargePilotUpdateRepository") as? String)
        .flatMap { $0.isEmpty ? nil : $0 }

    private var timer: Timer?
    private let checkInterval: TimeInterval = 6 * 3600

    /// The repository to check: the one built in, else one typed in Settings (for builds made before publishing).
    var repository: String? {
        get {
            builtInRepository ?? UserDefaults.standard.string(forKey: Key.repository).flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.repository)
            objectWillChange.send()
            startAutomaticChecks()
        }
    }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.automatic)
            objectWillChange.send()
            startAutomaticChecks()
        }
    }

    var repositoryURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)") } }

    private var feedURL: URL? { UserDefaults.standard.string(forKey: Key.feed).flatMap(URL.init(string:)) }

    var availableRelease: GitHubRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool { state == .checking || state == .downloading || state == .installing }

    /// True once, on the first launch after an in-app update.
    func consumeJustUpdated() -> Bool {
        let value = UserDefaults.standard.bool(forKey: Key.justUpdated)
        UserDefaults.standard.removeObject(forKey: Key.justUpdated)
        return value
    }

    func startAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard automaticChecks, repository != nil || feedURL != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        guard repository != nil || feedURL != nil else {
            state = .failed("Aucun dépôt GitHub n'est configuré.")
            return
        }
        if isBusy { return }
        state = .checking
        do {
            guard let release = try await fetchLatestRelease() else {
                state = .upToDate // nothing published yet
                return
            }
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Key.lastCheck)
            guard let current = AppVersion(currentVersion), release.isUpdate(from: current) else {
                state = .upToDate
                return
            }
            state = .available(release)
            if !userInitiated, UserDefaults.standard.string(forKey: Key.announced) != release.tagName {
                UserDefaults.standard.set(release.tagName, forKey: Key.announced)
                announce(release)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Checks, then installs straight away if there is something newer (the chargepilot://update link).
    func checkAndInstall() async {
        await check(userInitiated: true)
        if availableRelease != nil { await install() }
    }

    /// The API gives release notes but allows only 60 anonymous requests per hour per IP address;
    /// when it refuses, read the version from the public "latest release" redirect instead.
    private func fetchLatestRelease() async throws -> GitHubRelease? {
        if let feedURL {
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            return try GitHubRelease.decode(data)
        }
        guard let repository else { return nil }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChargePilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let status = (response as? HTTPURLResponse)?.statusCode {
            if status == 200, let release = try? GitHubRelease.decode(data) { return release }
            if status == 404 { return nil }
        }

        var page = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        page.httpMethod = "HEAD"
        page.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: page)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url else {
            throw UpdateError.message("GitHub est injoignable.")
        }
        // Without any release, GitHub lands on the releases list instead of a tag page.
        return GitHubRelease.fromLatestPage(final, repository: repository)
    }

    func install() async {
        guard case .available(let release) = state, let asset = release.appArchive, let expected = release.version else { return }
        let currentApp = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
            state = .failed("ChargePilot ne peut pas se remplacer dans \(currentApp.deletingLastPathComponent().path). Placez-la dans Applications.")
            return
        }

        state = .downloading
        do {
            // ".noindex" keeps Spotlight from listing the staged copy.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ChargePilotUpdate-\(UUID().uuidString).noindex")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: asset.browserDownloadUrl)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.message("Le téléchargement a échoué (\(http.statusCode)).")
            }
            let archive = work.appendingPathComponent(GitHubRelease.archiveName)
            try FileManager.default.moveItem(at: downloaded, to: archive)

            state = .installing
            let bundleID = Bundle.main.bundleIdentifier ?? ChargePilotIDs.appBundle
            let newApp = try await Task.detached {
                let app = try UpdateInstaller.extractApp(from: archive, into: work.appendingPathComponent("extracted"))
                try UpdateInstaller.validate(app: app, bundleIdentifier: bundleID, version: expected)
                return app
            }.value
            try UpdateInstaller.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                                 current: currentApp, with: newApp, relaunch: true, cleanUp: work)
            UserDefaults.standard.set(true, forKey: Key.justUpdated)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func announce(_ release: GitHubRelease) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "ChargePilot \(release.version?.description ?? release.tagName) est disponible"
        content.body = "Installez-la depuis Réglages › Mises à jour."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(release.tagName)", content: content, trigger: nil))
    }
}
