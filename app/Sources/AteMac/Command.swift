import Foundation

struct CommandResult {
    static let timedOut: Int32 = -2

    let status: Int32
    let output: String
}

/// Runs a process off the main thread and collects its output.
enum Command {
    /// Runs executable with args. stderr is mixed into the output unless
    /// discardStderr is set. With a timeout, kills the process and its
    /// children once the timeout passes, and returns timedOut. With a log,
    /// records the start, the end and the output there.
    static func run(_ executable: URL, _ args: [String], environment: [String: String] = [:],
                    input: Data? = nil, timeout: TimeInterval? = nil, discardStderr: Bool = false,
                    log: URL? = nil) async -> CommandResult {
        await Task.detached {
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = discardStderr ? FileHandle.nullDevice : pipe
            let stdin = Pipe()
            p.standardInput = input == nil ? FileHandle.nullDevice : stdin
            let command = "\(executable.lastPathComponent) \(args.joined(separator: " "))"
            let began = Date()
            if let log { Log.append(log, "\(command): started") }
            do {
                try p.run()
            } catch {
                if let log { Log.append(log, "\(command): could not run: \(error)") }
                return CommandResult(status: -1, output: "\(error)")
            }
            if let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            var timer: DispatchWorkItem?
            if let timeout {
                let pid = p.processIdentifier
                let item = DispatchWorkItem { killTree(pid) }
                DispatchQueue.global().asyncAfter(wallDeadline: .now() + timeout, execute: item)
                timer = item
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer?.cancel()
            let out = String(decoding: data, as: UTF8.self)
            let took = Log.duration(since: began)
            if p.terminationReason == .uncaughtSignal {
                if let log { Log.append(log, "\(command): timed out after \(took)\n\(Log.indent(out))") }
                return CommandResult(status: CommandResult.timedOut, output: out)
            }
            if let log {
                Log.append(log, "\(command): exit \(p.terminationStatus) after \(took)\n\(Log.indent(out))")
            }
            return CommandResult(status: p.terminationStatus, output: out)
        }.value
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
