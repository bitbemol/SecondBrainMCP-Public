import Testing
import Foundation
@testable import SecondBrainMCP

@Suite("VaultManager — Read Operations")
struct VaultManagerReadTests {

    private func makeTestVault() throws -> (String, ServerConfig) {
        let root = NSTemporaryDirectory() + "VaultManagerTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes/journal", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)

        // Create test notes
        let note1 = """
        ---
        title: App Redesign
        tags: [swift, project]
        created: 2026-03-01
        ---

        # App Redesign

        Planning the big redesign.
        """
        try note1.write(toFile: root + "/notes/projects/app-redesign.md", atomically: true, encoding: .utf8)

        let note2 = """
        # Daily Journal

        Today I worked on the MCP server.
        """
        try note2.write(toFile: root + "/notes/journal/2026-03-01.md", atomically: true, encoding: .utf8)

        let note3 = """
        ---
        title: Ideas
        tags: [idea, swift]
        ---

        Some random ideas.
        """
        try note3.write(toFile: root + "/notes/ideas.md", atomically: true, encoding: .utf8)

        let config = try ServerConfig.parse(arguments: ["binary", "--vault", root])
        return (root, config)
    }

    @Test("Read note returns content and metadata")
    func readNote() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let note = try await vault.readNote(relativePath: "notes/projects/app-redesign.md")
        #expect(note.metadata.title == "App Redesign")
        #expect(note.metadata.tags == ["swift", "project"])
        #expect(note.content.contains("Planning the big redesign"))
    }

    @Test("Read nonexistent note throws")
    func readMissing() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.readNote(relativePath: "notes/does-not-exist.md")
        }
    }

    @Test("Read note with wrong extension throws")
    func readWrongExtension() async throws {
        let (root, config) = try makeTestVault()
        // Create a non-markdown file
        try "secret".write(toFile: root + "/notes/secret.env", atomically: true, encoding: .utf8)
        let vault = VaultManager(config: config)

        await #expect(throws: PathValidator.PathError.self) {
            try await vault.readNote(relativePath: "notes/secret.env")
        }
    }

    @Test("Read note rejects path traversal")
    func readTraversal() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: PathValidator.PathError.self) {
            try await vault.readNote(relativePath: "../../../etc/passwd")
        }
    }

    @Test("List notes returns all notes recursively")
    func listAllNotes() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes()
        #expect(notes.count == 3)
        let paths = notes.map(\.relativePath)
        #expect(paths.contains("notes/projects/app-redesign.md"))
        #expect(paths.contains("notes/journal/2026-03-01.md"))
        #expect(paths.contains("notes/ideas.md"))
    }

    @Test("List notes scoped to subdirectory")
    func listSubdirectory() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes(directory: "notes/projects")
        #expect(notes.count == 1)
        #expect(notes[0].title == "App Redesign")
    }

    @Test("List notes filtered by tag")
    func listByTag() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes(tag: "swift")
        #expect(notes.count == 2)
        let titles = notes.map(\.title)
        #expect(titles.contains("App Redesign"))
        #expect(titles.contains("Ideas"))
    }

    @Test("List notes on empty vault returns empty array")
    func listEmpty() async throws {
        let root = NSTemporaryDirectory() + "VaultManagerTests-empty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let config = try ServerConfig.parse(arguments: ["binary", "--vault", root])
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes()
        #expect(notes.isEmpty)
    }

    @Test("Get note metadata returns structured info")
    func getMetadata() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let meta = try await vault.getNoteMetadata(relativePath: "notes/projects/app-redesign.md")
        #expect(meta.title == "App Redesign")
        #expect(meta.tags == ["swift", "project"])
        #expect(meta.created == "2026-03-01")
        #expect(meta.wordCount > 0)
    }

    @Test("Notes are sorted by modification date, newest first")
    func sortOrder() async throws {
        let (root, config) = try makeTestVault()
        // Touch one file to make it newest
        let path = root + "/notes/ideas.md"
        try "Updated content".write(toFile: path, atomically: true, encoding: .utf8)

        let vault = VaultManager(config: config)
        let notes = try await vault.listNotes()
        #expect(notes.first?.relativePath == "notes/ideas.md")
    }
}
