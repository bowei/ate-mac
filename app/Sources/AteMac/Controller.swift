import AppKit
import Foundation

enum Phase: Equatable {
    case unknown, notCreated, stopped, starting, running, stopping, failed
}

enum Prefs {
    static let cpus = "cpus"
    static let memoryGiB = "memoryGiB"
    static let diskGiB = "diskGiB"

    static func register() {
        UserDefaults.standard.register(defaults: [cpus: 4, memoryGiB: 6, diskGiB: 40])
    }
}

@MainActor
final class Controller: ObservableObject {
    @Published var phase: Phase = .unknown
    /// The guest status summary while running, or an error.
    @Published var detail = ""
    @Published var ready = false
    /// The bundled image differs from the one the instance was created from.
    @Published var newImage = false
    /// The latest stats from the guest, while it is running.
    @Published var stats: GuestStats?
    /// The status panel is open, so poll more often.
    var panelVisible = false {
        didSet { if panelVisible && !oldValue { Task { if !busy { await poll() } } } }
    }

    let paths = Paths()
    private lazy var lima = Lima(paths: paths)
    private var busy = false

    private let statusTimeout: TimeInterval = 20
    private var watchdog = Watchdog()

    // What the log last recorded, so it records changes rather than every poll.
    private var loggedStatus = ""
    private var loggedPods: [String: GuestStats.Pod.Health]?
    private var loggedNewImage = false
    private var unresponsiveSince: Date?

    init() {
        Prefs.register()
        try? FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let image = (try? readImageEnv())?["IMAGE_ID"] ?? "?"
        log("app: started, version \(version), image \(image), state in \(paths.state.path)")

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("app: Mac is going to sleep") }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.log("app: Mac woke from sleep; checking the guest")
                if !self.busy { await self.poll() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("app: quitting") }
        }
        Task { await pollLoop() }
    }

    var shellSetup: String {
        "export KUBECONFIG=\"\(paths.kubeconfig.path)\"\nexport PATH=\"\(paths.binDir.path):$PATH\"\n"
    }

    func start() {
        watchdog.reset()
        perform("start", .starting) { [self] in
            if await lima.status() == nil {
                log("start: no instance yet, creating one")
                try await create()
            } else {
                let d = UserDefaults.standard
                let cpus = d.integer(forKey: Prefs.cpus), memory = d.integer(forKey: Prefs.memoryGiB)
                log("start: applying settings: \(cpus) CPUs, \(memory) GiB memory")
                try await check(lima.run(["edit", "--tty=false", Lima.instance,
                                          "--cpus", String(cpus), "--memory", String(memory)]),
                                "apply settings")
            }
            log("start: booting the VM")
            try await check(lima.run(["start", "--tty=false", Lima.instance]), "start")
        }
    }

    func stop(then: (() -> Void)? = nil) {
        perform("stop", .stopping) { [self] in
            try await check(lima.run(["stop", Lima.instance]), "stop")
            then?()
        }
    }

    func restart() {
        watchdog.reset()
        perform("restart", .starting) { [self] in
            try await forceRestart()
        }
    }

    func reset() {
        watchdog.reset()
        perform("reset", .starting) { [self] in
            if await lima.status() != nil {
                log("reset: deleting the instance")
                try await check(lima.run(["delete", "--force", Lima.instance]), "delete")
            }
            try await create()
            log("reset: booting the VM")
            try await check(lima.run(["start", "--tty=false", Lima.instance]), "start")
        }
    }

    /// Stops the VM, forcing it if the guest doesn't shut down, then starts it.
    private func forceRestart() async throws {
        log("restart: stopping the VM")
        if await lima.run(["stop", Lima.instance], timeout: 90).status != 0 {
            log("restart: the VM didn't stop cleanly; forcing it")
            try await check(lima.run(["stop", "--force", Lima.instance]), "force stop")
        }
        log("restart: booting the VM")
        try await check(lima.run(["start", "--tty=false", Lima.instance]), "start")
    }

    private func create() async throws {
        let d = UserDefaults.standard
        let env = try readImageEnv()
        guard let port = env["API_PORT"] else { throw Failure("image.env has no API_PORT") }
        var t = try String(contentsOf: paths.template, encoding: .utf8)
        for (k, v) in [
            "@IMAGE@": paths.image.path,
            "@CPUS@": String(d.integer(forKey: Prefs.cpus)),
            "@MEMORY@": "\(d.integer(forKey: Prefs.memoryGiB))GiB",
            "@DISK@": "\(d.integer(forKey: Prefs.diskGiB))GiB",
            "@APIPORT@": port,
        ] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        try t.write(to: paths.renderedTemplate, atomically: true, encoding: .utf8)
        log("create: wrote \(paths.renderedTemplate.path): \(d.integer(forKey: Prefs.cpus)) CPUs, "
            + "\(d.integer(forKey: Prefs.memoryGiB)) GiB memory, \(d.integer(forKey: Prefs.diskGiB)) GiB disk, "
            + "API port \(port), image \(env["IMAGE_ID"] ?? "?")")
        log("create: creating the instance from \(paths.image.path)")
        try await check(lima.run(["create", "--tty=false", "--name", Lima.instance, paths.renderedTemplate.path]),
                        "create")

        let fm = FileManager.default
        try? fm.removeItem(at: paths.kubeconfig)
        try fm.copyItem(at: paths.bundledKubeconfig, to: paths.kubeconfig)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.kubeconfig.path)
        try (env["IMAGE_ID"] ?? "").write(to: paths.installedImage, atomically: true, encoding: .utf8)
        log("create: installed the kubeconfig at \(paths.kubeconfig.path)")
    }

    private func perform(_ name: String, _ phase: Phase, _ body: @escaping () async throws -> Void) {
        guard !busy else {
            log("\(name): skipped, another action is running")
            return
        }
        busy = true
        self.phase = phase
        ready = false
        detail = ""
        let began = Date()
        log("\(name): started")
        Task {
            do {
                try await body()
                log("\(name): finished in \(Log.duration(since: began))")
            } catch {
                self.phase = .failed
                detail = "\(error)"
                log("\(name): failed after \(Log.duration(since: began)): \(error)")
            }
            busy = false
            await poll()
        }
    }

    private func pollLoop() async {
        while true {
            if !busy { await poll() }
            try? await Task.sleep(for: .seconds(panelVisible ? 2 : 5))
        }
    }

    private func poll() async {
        await pollOnce()
        logChanges()
    }

    private func pollOnce() async {
        let s = await lima.status()
        guard !busy else { return }
        switch s {
        case nil:
            if phase != .failed { phase = .notCreated }
            newImage = false
            stats = nil
            return
        case "Running":
            if watchdog.gaveUp { return }
            phase = .running
            let script = try? Data(contentsOf: paths.statsScript)
            let r = await lima.guest(["python3", "-"], input: script, timeout: statusTimeout)
            guard !busy else { return }
            // ate-mac-stats.py exits 0 or 1. Anything else means it never
            // ran: ssh failed or timed out.
            if r.status == 0 || r.status == 1 {
                if let since = unresponsiveSince {
                    log("guest: responding again after \(Log.duration(since: since))")
                    unresponsiveSince = nil
                }
                watchdog.responsive()
                if let s = try? JSONDecoder().decode(GuestStats.self, from: Data(lastLine(r.output).utf8)) {
                    stats = s
                    ready = s.ready
                    detail = s.summary
                } else {
                    let unreadable = "unreadable status, see Show Log"
                    if detail != unreadable {
                        log("guest: ate-mac-stats.py printed something other than its JSON\n\(Log.indent(r.output))")
                    }
                    stats = nil
                    ready = false
                    detail = unreadable
                }
            } else {
                if unresponsiveSince == nil {
                    unresponsiveSince = Date()
                    let why = r.status == CommandResult.timedOut ? "timed out" : "exit \(r.status)"
                    log("guest: not responding (\(why))\n\(Log.indent(r.output))")
                }
                ready = false
                stats = nil
                handle(watchdog.unresponsive(at: Date()))
            }
        default:
            if phase != .failed { phase = .stopped }
            ready = false
            stats = nil
        }
        let installed = (try? String(contentsOf: paths.installedImage, encoding: .utf8)) ?? ""
        newImage = installed != ((try? readImageEnv())?["IMAGE_ID"] ?? "")
    }

    /// Logs the overall status, each pod's health, and the new-image hint when
    /// they change.
    private func logChanges() {
        let status = "\(phase)" + (detail.isEmpty ? "" : ": \(detail)")
        if status != loggedStatus {
            log("status: \(status)")
            loggedStatus = status
        }
        if newImage != loggedNewImage {
            log(newImage ? "app: the bundled image differs from the instance's; Reset to use it"
                         : "app: the instance uses the bundled image")
            loggedNewImage = newImage
        }

        guard let stats else {
            loggedPods = nil
            return
        }
        let now = Dictionary(uniqueKeysWithValues: stats.pods.map { ($0.id, $0.health) })
        defer { loggedPods = now }
        guard let before = loggedPods else {
            let healthy = now.values.filter { $0 == .healthy }.count
            log("pods: \(now.count) total, \(healthy) healthy")
            return
        }
        for pod in stats.pods {
            let why = pod.detail.isEmpty ? "" : " (\(pod.detail))"
            if let old = before[pod.id] {
                if old != pod.health { log("pod \(pod.id): \(old.rawValue) -> \(pod.health.rawValue)\(why)") }
            } else {
                log("pod \(pod.id): appeared, \(pod.health.rawValue)\(why)")
            }
        }
        for id in before.keys where now[id] == nil {
            log("pod \(id): gone")
        }
    }

    private func log(_ text: String) {
        Log.append(paths.log, text)
    }

    private func handle(_ action: Watchdog.Action) {
        switch action {
        case .none:
            detail = watchdog.armed ? "guest not responding" : "waiting for the guest"
        case .giveUp:
            log("watchdog: guest hung again after a restart; giving up")
            phase = .failed
            detail = "guest keeps hanging; try Restart or Reset"
        case .restart:
            log("watchdog: guest not responding for \(Int(watchdog.unresponsiveLimit))s; restarting")
            perform("watchdog restart", .starting) { [self] in
                do {
                    try await forceRestart()
                } catch {
                    log("watchdog: restart failed; giving up")
                    watchdog.restartFailed()
                    throw error
                }
            }
        }
    }

    /// stderr is mixed into the output, so skip anything before the JSON line.
    private func lastLine(_ output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? ""
    }

    private func readImageEnv() throws -> [String: String] {
        var env: [String: String] = [:]
        for line in try String(contentsOf: paths.imageEnv, encoding: .utf8).split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { env[kv[0]] = kv[1] }
        }
        return env
    }

    private func check(_ r: CommandResult, _ what: String) throws {
        if r.status != 0 {
            throw Failure("\(what) failed, see Show Log")
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
