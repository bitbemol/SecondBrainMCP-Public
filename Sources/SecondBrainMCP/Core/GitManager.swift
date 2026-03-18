import Foundation

/// Serialized git operations via /usr/bin/git. Actor because git commands
/// must not run concurrently against the same repo (index corruption).
actor GitManager {

    private let repoPath: String
    private static let gitPath = "/usr/bin/git"

    enum GitError: Error, CustomStringConvertible {
        case gitNotFound
        case commandFailed(command: String, exitCode: Int32, stderr: String)
        case notARepository

        var description: String {
            switch self {
            case .gitNotFound:
                return "Git not found at \(gitPath)"
            case .commandFailed(let cmd, let code, let stderr):
                return "Git command failed (\(cmd), exit \(code)): \(stderr)"
            case .notARepository:
                return "Not a git repository"
            }
        }
    }

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    // MARK: - Public API

    /// Initialize git repo if needed. If already a repo, snapshot any uncommitted changes.
    func ensureRepository() async throws {
        if isGitRepository() {
            try await snapshotIfDirty()
        } else {
            try await initRepository()
        }
    }

    /// Stage specific files and commit with a sanitized message.
    func commitChange(files: [String], message: String) async throws {
        guard !files.isEmpty else { return }

        // Stage each file individually using -- to prevent flag injection
        for file in files {
            try await run(["add", "--", file])
        }

        let sanitized = Self.sanitizeCommitMessage(message)
        try await run(["commit", "-m", sanitized])
    }

    /// Stage a file deletion and commit. Uses `git add -A` scoped to the parent
    /// directory to handle case-insensitive filesystems (macOS APFS/HFS+) where
    /// the working tree path casing may differ from the git index entry.
    func commitDeletion(path: String, message: String) async throws {
        let parentDir = (path as NSString).deletingLastPathComponent
        try await run(["add", "-A", "--", parentDir.isEmpty ? "." : parentDir])
        let sanitized = Self.sanitizeCommitMessage(message)
        try await run(["commit", "-m", sanitized])
    }

    /// Stage moved files (deletion at source, addition at destination) and commit.
    /// Uses `git add -A` on source parent dirs to handle case-insensitive filesystem.
    func commitMoves(moves: [(source: String, destination: String)], message: String) async throws {
        guard !moves.isEmpty else { return }

        for move in moves {
            // Stage the deletion at the old location
            let sourceParent = (move.source as NSString).deletingLastPathComponent
            try await run(["add", "-A", "--", sourceParent.isEmpty ? "." : sourceParent])
            // Stage the new file at the destination
            try await run(["add", "--", move.destination])
        }

        let sanitized = Self.sanitizeCommitMessage(message)
        try await run(["commit", "-m", sanitized])
    }

    /// Get log entries for a specific file.
    func log(forFile file: String, maxEntries: Int = 10) async throws -> [LogEntry] {
        let output = try await run([
            "log",
            "--format=%H%n%aI%n%s",
            "-n", String(maxEntries),
            "--", file
        ])
        return Self.parseLogOutput(output)
    }

    /// Get log entries for the entire repo.
    func log(maxEntries: Int = 20, since: String? = nil) async throws -> [LogEntry] {
        var args = ["log", "--format=%H%n%aI%n%s", "-n", String(maxEntries)]
        if let since {
            args.append(contentsOf: ["--since", since])
        }
        let output = try await run(args)
        return Self.parseLogOutput(output)
    }

    /// Get the content of a file at a specific commit.
    func showFile(path: String, atCommit commit: String) async throws -> String {
        let sanitizedCommit = Self.sanitizeRef(commit)
        return try await run(["show", "\(sanitizedCommit):\(path)"])
    }

    /// Checkout a file from a specific commit (used for revert).
    func checkoutFile(path: String, fromCommit commit: String) async throws {
        let sanitizedCommit = Self.sanitizeRef(commit)
        try await run(["checkout", sanitizedCommit, "--", path])
    }

    /// Get list of files changed in a specific commit.
    func filesChanged(inCommit commit: String) async throws -> [String] {
        let sanitizedCommit = Self.sanitizeRef(commit)
        let output = try await run(["diff-tree", "--no-commit-id", "-r", "--name-only", sanitizedCommit])
        return output.split(separator: "\n").map(String.init)
    }

    /// Check if the working tree has uncommitted changes.
    func isDirty() async throws -> Bool {
        let output = try await run(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Private

    private func isGitRepository() -> Bool {
        FileManager.default.fileExists(atPath: repoPath + "/.git")
    }

    private func initRepository() async throws {
        try await run(["init"])
        try await createGitignore()

        // Stage everything and make initial commit
        try await run(["add", "."])
        try await run(["commit", "-m", "[SecondBrainMCP] Initial commit of existing vault"])
    }

    private func snapshotIfDirty() async throws {
        guard try await isDirty() else { return }
        try await run(["add", "."])
        try await run(["commit", "-m", "[SecondBrainMCP] Snapshot of uncommitted changes on startup"])
    }

    private func createGitignore() async throws {
        let gitignorePath = repoPath + "/.gitignore"
        let content = """
        # SecondBrainMCP internals
        .secondbrain-mcp/
        .trash/

        # PDF reference library (large binary files — not suitable for git)
        references/

        # macOS
        .DS_Store

        # Common editor files
        *.swp
        *~
        """
        try content.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
    }

    /// Execute a git command and return stdout. All git execution flows through here.
    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: Self.gitPath) else {
            throw GitError.gitNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let cmdStr = arguments.joined(separator: " ")
            throw GitError.commandFailed(command: cmdStr, exitCode: process.terminationStatus, stderr: stderr)
        }

        return stdout
    }

    // MARK: - Sanitization

    /// Strip anything from a commit message that could be dangerous.
    /// Allow only: letters, numbers, whitespace, and safe punctuation.
    static func sanitizeCommitMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace || "-_./[]():,".contains($0) }
    }

    /// Sanitize a git ref (commit hash or branch name).
    /// Only allow hex characters for commit hashes, alphanumeric + limited punctuation for refs.
    static func sanitizeRef(_ ref: String) -> String {
        ref.filter { $0.isHexDigit || $0.isLetter || "-_/.".contains($0) }
    }

    // MARK: - Log Parsing

    struct LogEntry: Sendable {
        let hash: String
        let date: String
        let message: String
    }

    /// Parse git log output formatted as: hash\ndate\nsubject (repeating blocks of 3 lines).
    static func parseLogOutput(_ output: String) -> [LogEntry] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [LogEntry] = []
        var i = 0
        while i + 2 < lines.count {
            let hash = lines[i]
            let date = lines[i + 1]
            let message = lines[i + 2]
            if !hash.isEmpty {
                entries.append(LogEntry(hash: hash, date: date, message: message))
            }
            i += 3
        }
        return entries
    }
}
