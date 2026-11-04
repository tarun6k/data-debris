import Foundation

/// The docker command-line client, spoken to over its local socket. Every
/// call names explicit arguments for one object; nothing here prunes
/// blindly. This file is allowlisted for Process() in NetworkHostsTests.
public struct DockerCLI: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        case notInstalled
        case timedOut
        case failed(status: Int32, stderr: String)
    }

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Where Docker Desktop, Homebrew, Rancher Desktop and the docker
    /// installer put the client. PATH is not consulted: an app launched by
    /// Finder has none worth reading.
    public static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            home.appendingPathComponent(".docker/bin/docker").path,
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home.appendingPathComponent(".rd/bin/docker").path,
        ]
    }

    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DockerCLI? {
        candidatePaths(home: home)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { DockerCLI(executable: URL(fileURLWithPath: $0)) }
    }

    /// True when the active docker context talks to a unix socket on this
    /// Mac. A context pointing at tcp:// or ssh:// would make the app reach
    /// a host the Privacy & Security sheet never promised, so that setup is
    /// treated as "no docker". `context inspect` reads a file; no daemon.
    public func endpointIsLocalSocket(timeout: TimeInterval = 3) -> Bool {
        guard let data = try? run(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                                  timeout: timeout) else { return false }
        let host = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return host.hasPrefix("unix://")
    }

    /// Runs `docker <arguments>` and returns stdout. DOCKER_* variables are
    /// stripped from the environment so the context on disk alone decides
    /// where the socket is. Past `timeout` the process is terminated (then
    /// killed) and `.timedOut` is thrown.
    public func run(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw Failure.notInstalled
        }
        // Both pipes drain off this thread: a chatty docker must never block
        // on a full pipe while we wait for it to exit.
        let out = PipeReader(stdout.fileHandleForReading)
        let err = PipeReader(stderr.fileHandleForReading)

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            throw Failure.timedOut
        }
        let output = out.data()
        let errorText = String(decoding: err.data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.failed(status: process.terminationStatus, stderr: errorText)
        }
        return output
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("DOCKER_") { env.removeValue(forKey: key) }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin" }
        return env
    }
}

/// Reads a pipe to EOF on a background thread.
private final class PipeReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private var bytes = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            bytes = handle.readDataToEndOfFile()
            group.leave()
        }
    }

    func data() -> Data {
        group.wait()
        return bytes
    }
}
