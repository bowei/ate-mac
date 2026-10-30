import Foundation

/// Paths inside the app bundle and the per-user state directory.
struct Paths {
    let resources: URL
    let state: URL

    init() {
        resources = Bundle.main.resourceURL!
        state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ate-mac")
    }

    var limactl: URL { resources.appendingPathComponent("lima/bin/limactl") }
    var binDir: URL { resources.appendingPathComponent("bin") }
    var image: URL { resources.appendingPathComponent("substrate.qcow2") }
    var template: URL { resources.appendingPathComponent("runtime.yaml.tmpl") }
    var bundledKubeconfig: URL { resources.appendingPathComponent("kubeconfig") }
    var imageEnv: URL { resources.appendingPathComponent("image.env") }
    var statsScript: URL { resources.appendingPathComponent("ate-mac-stats.py") }

    var limaHome: URL { state.appendingPathComponent("lima") }
    var kubeconfig: URL { state.appendingPathComponent("kubeconfig") }
    var renderedTemplate: URL { state.appendingPathComponent("substrate.yaml") }
    var installedImage: URL { state.appendingPathComponent("image-id") }
    var log: URL { state.appendingPathComponent("app.log") }
}

struct CommandResult {
    static let timedOut: Int32 = -2

    let status: Int32
    let output: String
}

/// Runs the bundled limactl with LIMA_HOME pointing at the state directory.
struct Lima {
    static let instance = "substrate"

    let paths: Paths

    /// Runs limactl. With a timeout, kills it and its children (limactl shell
    /// runs ssh as a child) once the timeout passes, and returns timedOut.
    func run(_ args: [String], input: Data? = nil, timeout: TimeInterval? = nil,
             logOutput: Bool = true) async -> CommandResult {
        let paths = self.paths
        return await Task.detached {
            let p = Process()
            p.executableURL = paths.limactl
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["LIMA_HOME"] = paths.limaHome.path
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let stdin = Pipe()
            p.standardInput = input == nil ? FileHandle.nullDevice : stdin
            let command = "limactl \(args.joined(separator: " "))"
            let began = Date()
            if logOutput { Log.append(paths.log, "\(command): started") }
            do {
                try p.run()
            } catch {
                Log.append(paths.log, "\(command): could not run: \(error)")
                return CommandResult(status: -1, output: "\(error)")
            }
            if let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            var timer: DispatchWorkItem?
            if let timeout {
                let pid = p.processIdentifier
                let item = DispatchWorkItem { Lima.killTree(pid) }
                DispatchQueue.global().asyncAfter(wallDeadline: .now() + timeout, execute: item)
                timer = item
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer?.cancel()
            let out = String(decoding: data, as: UTF8.self)
            let took = Log.duration(since: began)
            if p.terminationReason == .uncaughtSignal {
                if logOutput { Log.append(paths.log, "\(command): timed out after \(took)\n\(Log.indent(out))") }
                return CommandResult(status: CommandResult.timedOut, output: out)
            }
            if logOutput {
                Log.append(paths.log, "\(command): exit \(p.terminationStatus) after \(took)\n\(Log.indent(out))")
            }
            return CommandResult(status: p.terminationStatus, output: out)
        }.value
    }

    /// The instance status, such as "Running" or "Stopped", or nil if it doesn't exist.
    func status() async -> String? {
        let r = await run(["list", "--format", "{{.Status}}", Lima.instance], logOutput: false)
        // stderr is mixed in, so skip any warnings before the status.
        let s = r.output.split(separator: "\n").last.map(String.init) ?? ""
        return r.status == 0 && !s.isEmpty ? s : nil
    }

    /// Runs a command in the guest as root.
    func guest(_ args: [String], input: Data? = nil, timeout: TimeInterval) async -> CommandResult {
        await run(["shell", "--workdir", "/", Lima.instance, "sudo"] + args,
                  input: input, timeout: timeout, logOutput: false)
    }

    private static func killTree(_ pid: pid_t) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()
        kill(pid, SIGKILL)
    }
}
