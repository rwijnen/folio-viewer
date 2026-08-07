import Foundation

/// Runs `git` as a subprocess.
///
/// Folio shells out to the git already on the machine rather than linking a library.
/// That is not a shortcut. The reader's `~/.gitconfig`, their credential helper, their
/// SSH agent, their `pre-commit` hook and their signing key all come along, and a commit
/// Folio makes is indistinguishable from one they made in a terminal. Linking libgit2
/// would mean reimplementing every one of those, and would add this project's second
/// dependency to do it.
struct Git: Sendable {

    /// Where git lives. Apple ships one at this path on every supported system; it is a
    /// stored property so a test can point somewhere else.
    var executable = URL(fileURLWithPath: "/usr/bin/git")
    /// The directory commands run in, which is how git finds the repository.
    var workingDirectory: URL
    /// Layered on top of the inherited environment. Tests use it to seal git off from
    /// the developer's own configuration; the app leaves it empty.
    var environment: [String: String] = [:]

    /// Long enough that a slow disk or a `pre-commit` hook finishes, short enough that a
    /// wedged command does not hold the interface.
    static let localTimeout: TimeInterval = 30
    /// Talking to a remote. Generous, because it may be a large push over a poor link.
    static let remoteTimeout: TimeInterval = 120

    // MARK: - Results

    struct Result: Sendable {
        var status: Int32
        var output: String
        var errorOutput: String

        var succeeded: Bool { status == 0 }
        /// Output with the single trailing newline git adds removed.
        var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    struct Failure: LocalizedError, Sendable {
        var command: String
        var status: Int32
        var message: String

        var errorDescription: String? {
            message.isEmpty ? "git \(command) exited with status \(status)." : message
        }
    }

    // MARK: - Running

    /// Runs a command and returns whatever it did, success or not.
    func run(_ arguments: [String], timeout: TimeInterval = Git.localTimeout) async -> Result {
        let executable = executable
        let workingDirectory = workingDirectory
        let environment = environment
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.execute(executable: executable,
                                                            arguments: arguments,
                                                            workingDirectory: workingDirectory,
                                                            extraEnvironment: environment,
                                                            timeout: timeout))
            }
        }
    }

    /// Runs a command that is expected to work, throwing what git said if it did not.
    @discardableResult
    func require(_ arguments: [String], timeout: TimeInterval = Git.localTimeout) async throws -> String {
        let result = await run(arguments, timeout: timeout)
        guard result.succeeded else {
            throw Failure(command: arguments.joined(separator: " "),
                          status: result.status,
                          message: Self.describe(result))
        }
        return result.trimmed
    }

    /// The most useful sentence git produced. Errors go to stderr, but some commands
    /// explain themselves on stdout, so fall back to it rather than showing nothing.
    static func describe(_ result: Result) -> String {
        let stderr = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.trimmed
        if !stdout.isEmpty { return stdout }
        return result.status == Self.timeoutStatus
            ? "git did not finish in time and was stopped."
            : ""
    }

    /// Reported when we killed the process ourselves. 128 + SIGTERM, the shell's
    /// convention, so it cannot collide with an exit code git chose.
    static let timeoutStatus: Int32 = 143

    // MARK: - The subprocess

    private static let queue = DispatchQueue(label: "folio.git", qos: .userInitiated,
                                             attributes: .concurrent)

    private static func execute(executable: URL,
                                arguments: [String],
                                workingDirectory: URL,
                                extraEnvironment: [String: String],
                                timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment(adding: extraEnvironment)

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        // Nothing is ever typed at git. Without this a command that asks a question
        // inherits Folio's stdin and waits at it for ever.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "",
                          errorOutput: "Could not run git: \(error.localizedDescription)")
        }

        // Drain both pipes at once. Waiting on one while the other fills its 64 KB
        // buffer deadlocks the child, and `git push --verbose` easily writes that much.
        //
        // Read through handlers rather than a blocking `readDataToEndOfFile` on each: the
        // blocking version costs three tied-up threads per command, and dropping a couple
        // of dozen documents onto Folio at once would then be enough to exhaust GCD's
        // pool. This way a command occupies one thread, the one waiting below.
        let reading = DispatchGroup()
        let outputReader = PipeReader(output, group: reading)
        let errorReader = PipeReader(errorOutput, group: reading)

        var timedOut = false
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            // Give it a moment to die politely, then insist.
            if reading.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                reading.wait()
            }
        }
        process.waitUntilExit()

        return Result(status: timedOut ? timeoutStatus : process.terminationStatus,
                      output: String(decoding: outputReader.data, as: UTF8.self),
                      errorOutput: String(decoding: errorReader.data, as: UTF8.self))
    }

    /// Accumulates one pipe's output as it arrives, and leaves `group` at end of file.
    ///
    /// The handler runs on a queue Dispatch owns, so nothing of ours is blocked while
    /// git is writing. The lock is not ceremony: the handler thread appends and the
    /// thread that ran the command reads, and those are different threads.
    private final class PipeReader {

        private let lock = NSLock()
        private var buffer = Data()

        init(_ pipe: Pipe, group: DispatchGroup) {
            group.enter()
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    // Empty means end of file, and the handler must be cleared or it
                    // fires for ever against a closed descriptor.
                    handle.readabilityHandler = nil
                    group.leave()
                    return
                }
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
            }
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    private static func environment(adding extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        // Never let git stop and ask. A push whose stored credentials have expired would
        // otherwise sit for ever waiting at a terminal that does not exist; with this it
        // fails immediately and we can say why.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Read-only commands should not take the index lock. Folio asks for status while
        // the reader may be running git in a terminal on the same repository, and a
        // status refresh has no business making their command fail.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // A pager would never exit, since there is no terminal to quit it from.
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"

        // An app launched from Finder inherits launchd's short PATH, so a credential
        // helper or a hook interpreter installed by Homebrew would not be found — the
        // same push that works in Terminal would fail here. Extend the path rather than
        // replacing it, and put the inherited entries first so the reader's own choice
        // still wins.
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let additions = ["/opt/homebrew/bin", "/usr/local/bin"]
            .filter { !inherited.split(separator: ":").contains(Substring($0)) }
        if !additions.isEmpty {
            environment["PATH"] = ([inherited] + additions).joined(separator: ":")
        }

        environment.merge(extra) { _, new in new }
        return environment
    }
}
