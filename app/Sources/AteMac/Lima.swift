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

    var limaHome: URL { state.appendingPathComponent("lima") }
    var kubeconfig: URL { state.appendingPathComponent("kubeconfig") }
    var renderedTemplate: URL { state.appendingPathComponent("substrate.yaml") }
    var installedRev: URL { state.appendingPathComponent("image-rev") }
    var log: URL { state.appendingPathComponent("app.log") }
}

struct CommandResult {
    let status: Int32
    let output: String
}

/// Runs the bundled limactl with LIMA_HOME pointing at the state directory.
struct Lima {
    static let instance = "substrate"

    let paths: Paths

    func run(_ args: [String], logOutput: Bool = true) async -> CommandResult {
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
            do {
                try p.run()
            } catch {
                return CommandResult(status: -1, output: "\(error)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            if logOutput {
                Log.append(paths.log, "$ limactl \(args.joined(separator: " "))\n\(out)exit \(p.terminationStatus)\n")
            }
            return CommandResult(status: p.terminationStatus, output: out)
        }.value
    }

    /// The instance status, such as "Running" or "Stopped", or nil if it doesn't exist.
    func status() async -> String? {
        let r = await run(["list", "--format", "{{.Status}}", Lima.instance], logOutput: false)
        let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !s.isEmpty ? s : nil
    }

    /// Runs a command in the guest as root.
    func guest(_ args: [String]) async -> CommandResult {
        await run(["shell", "--workdir", "/", Lima.instance, "sudo"] + args, logOutput: false)
    }
}

enum Log {
    static func append(_ url: URL, _ text: String) {
        let line = "[\(Date())] \(text)"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
