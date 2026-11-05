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

extension Paths {
    var kubectlAte: URL { binDir.appendingPathComponent("kubectl-ate") }
}

/// Runs the bundled limactl with LIMA_HOME pointing at the state directory.
struct Lima {
    static let instance = "substrate"

    let paths: Paths

    /// Runs limactl. With a timeout, kills it and its children (limactl shell
    /// runs ssh as a child) once the timeout passes, and returns timedOut.
    func run(_ args: [String], input: Data? = nil, timeout: TimeInterval? = nil,
             logOutput: Bool = true) async -> CommandResult {
        await Command.run(paths.limactl, args, environment: ["LIMA_HOME": paths.limaHome.path],
                          input: input, timeout: timeout, log: logOutput ? paths.log : nil)
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
}
