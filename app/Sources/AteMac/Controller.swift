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
        UserDefaults.standard.register(defaults: [cpus: 6, memoryGiB: 12, diskGiB: 60])
    }
}

@MainActor
final class Controller: ObservableObject {
    @Published var phase: Phase = .unknown
    /// Output of ate-mac-status while running, or an error.
    @Published var detail = ""
    @Published var ready = false
    /// The bundled image differs from the one the instance was created from.
    @Published var newImage = false

    let paths = Paths()
    private lazy var lima = Lima(paths: paths)
    private var busy = false

    init() {
        Prefs.register()
        try? FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        Task { await pollLoop() }
    }

    var shellSetup: String {
        "export KUBECONFIG=\"\(paths.kubeconfig.path)\"\nexport PATH=\"\(paths.binDir.path):$PATH\"\n"
    }

    func start() {
        perform(.starting) { [self] in
            if await lima.status() == nil {
                try await create()
            } else {
                let d = UserDefaults.standard
                try await check(lima.run(["edit", "--tty=false", Lima.instance,
                                          "--cpus", String(d.integer(forKey: Prefs.cpus)),
                                          "--memory", String(d.integer(forKey: Prefs.memoryGiB))]),
                                "apply settings")
            }
            try await check(lima.run(["start", "--tty=false", Lima.instance]), "start")
        }
    }

    func stop(then: (() -> Void)? = nil) {
        perform(.stopping) { [self] in
            try await check(lima.run(["stop", Lima.instance]), "stop")
            then?()
        }
    }

    func reset() {
        perform(.starting) { [self] in
            if await lima.status() != nil {
                try await check(lima.run(["delete", "--force", Lima.instance]), "delete")
            }
            try await create()
            try await check(lima.run(["start", "--tty=false", Lima.instance]), "start")
        }
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
        try await check(lima.run(["create", "--tty=false", "--name", Lima.instance, paths.renderedTemplate.path]),
                        "create")

        let fm = FileManager.default
        try? fm.removeItem(at: paths.kubeconfig)
        try fm.copyItem(at: paths.bundledKubeconfig, to: paths.kubeconfig)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.kubeconfig.path)
        try (env["SUBSTRATE_REV"] ?? "").write(to: paths.installedRev, atomically: true, encoding: .utf8)
    }

    private func perform(_ phase: Phase, _ body: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        self.phase = phase
        ready = false
        detail = ""
        Task {
            do {
                try await body()
            } catch {
                self.phase = .failed
                detail = "\(error)"
            }
            busy = false
            await poll()
        }
    }

    private func pollLoop() async {
        while true {
            if !busy { await poll() }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func poll() async {
        let s = await lima.status()
        guard !busy else { return }
        switch s {
        case nil:
            if phase != .failed { phase = .notCreated }
            newImage = false
            return
        case "Running":
            phase = .running
            let r = await lima.guest(["/usr/local/bin/ate-mac-status"])
            ready = r.status == 0
            detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            if phase != .failed { phase = .stopped }
            ready = false
        }
        let installed = (try? String(contentsOf: paths.installedRev, encoding: .utf8)) ?? ""
        newImage = installed != ((try? readImageEnv())?["SUBSTRATE_REV"] ?? "")
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
