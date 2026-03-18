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

// MARK: - Move Operations

@Suite("VaultManager — Move Note")
struct VaultManagerMoveTests {

    private func makeTestVault() throws -> (String, ServerConfig) {
        let root = NSTemporaryDirectory() + "VaultMoveTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/ideas", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)

        try "# ML Stuff\nSome notes on ML.".write(
            toFile: root + "/notes/ideas/ml-stuff.md", atomically: true, encoding: .utf8
        )
        try "# Swift Tips\nUseful Swift patterns.".write(
            toFile: root + "/notes/ideas/swift-tips.md", atomically: true, encoding: .utf8
        )
        try "# App\nMain project.".write(
            toFile: root + "/notes/projects/app.md", atomically: true, encoding: .utf8
        )

        let config = try ServerConfig.parse(arguments: ["binary", "--vault", root])
        return (root, config)
    }

    // MARK: - Single Move

    @Test("Move note to new path")
    func moveBasic() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/projects/ml.md")
        #expect(result.contains("Moved:"))

        // Source gone, destination exists with same content
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/ideas/ml-stuff.md"))
        let content = try String(contentsOfFile: root + "/notes/projects/ml.md", encoding: .utf8)
        #expect(content.contains("ML Stuff"))
    }

    @Test("Move creates destination parent directories")
    func moveCreatesParentDirs() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/deep/nested/dir/ml.md")

        #expect(FileManager.default.fileExists(atPath: root + "/notes/deep/nested/dir/ml.md"))
    }

    @Test("Move cleans up empty source directories")
    func moveCleanupEmptyDirs() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        // Move both files out of ideas/
        try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/projects/ml.md")
        try await vault.moveNote(source: "notes/ideas/swift-tips.md", destination: "notes/projects/swift-tips.md")

        // ideas/ directory should be cleaned up
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/ideas"))
    }

    @Test("Move rejects source outside notes/")
    func moveSourceOutsideNotes() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNote(source: "references/book.pdf", destination: "notes/book.md")
        }
    }

    @Test("Move rejects destination outside notes/")
    func moveDestOutsideNotes() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "references/ml.md")
        }
    }

    @Test("Move rejects nonexistent source")
    func moveMissingSource() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNote(source: "notes/ghost.md", destination: "notes/elsewhere.md")
        }
    }

    @Test("Move rejects when destination already exists")
    func moveDestExists() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/projects/app.md")
        }
    }

    @Test("Move rejects same source and destination")
    func moveSamePath() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/ideas/ml-stuff.md")
        }
    }

    @Test("Move rejects invalid extension")
    func moveInvalidExtension() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: PathValidator.PathError.self) {
            try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/ideas/ml-stuff.txt")
        }
    }

    @Test("Move rejects path traversal")
    func moveTraversal() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: (any Error).self) {
            try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/../../etc/evil.md")
        }
    }

    @Test("Case-only rename works on macOS")
    func moveCaseOnlyRename() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        try await vault.moveNote(source: "notes/ideas/ml-stuff.md", destination: "notes/ideas/ML-Stuff.md")

        // The file should exist with the new casing
        // On case-insensitive FS, we verify by checking the directory listing
        let contents = try FileManager.default.contentsOfDirectory(atPath: root + "/notes/ideas")
        #expect(contents.contains("ML-Stuff.md"))
    }

    // MARK: - Batch Move

    @Test("Batch move multiple notes")
    func moveBatch() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.moveNotes(moves: [
            .init(source: "notes/ideas/ml-stuff.md", destination: "notes/projects/ml.md"),
            .init(source: "notes/ideas/swift-tips.md", destination: "notes/projects/swift-tips.md")
        ])

        #expect(result.contains("Moved 2 note(s)"))
        #expect(FileManager.default.fileExists(atPath: root + "/notes/projects/ml.md"))
        #expect(FileManager.default.fileExists(atPath: root + "/notes/projects/swift-tips.md"))
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/ideas/ml-stuff.md"))
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/ideas/swift-tips.md"))
    }

    @Test("Batch rejects empty moves array")
    func moveBatchEmpty() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNotes(moves: [])
        }
    }

    @Test("Batch rejects more than 20 moves")
    func moveBatchTooMany() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let moves = (0..<21).map {
            VaultManager.MoveOperation(source: "notes/a\($0).md", destination: "notes/b\($0).md")
        }

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNotes(moves: moves)
        }
    }

    @Test("Batch rejects duplicate destinations")
    func moveBatchDuplicateDest() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNotes(moves: [
                .init(source: "notes/ideas/ml-stuff.md", destination: "notes/target.md"),
                .init(source: "notes/ideas/swift-tips.md", destination: "notes/target.md")
            ])
        }
    }

    @Test("Batch rejects duplicate sources")
    func moveBatchDuplicateSource() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNotes(moves: [
                .init(source: "notes/ideas/ml-stuff.md", destination: "notes/a.md"),
                .init(source: "notes/ideas/ml-stuff.md", destination: "notes/b.md")
            ])
        }
    }

    @Test("Batch rejects source/destination overlap")
    func moveBatchOverlap() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        // A->B and B->C: B is both a destination and a source
        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNotes(moves: [
                .init(source: "notes/ideas/ml-stuff.md", destination: "notes/ideas/swift-tips.md"),
                .init(source: "notes/ideas/swift-tips.md", destination: "notes/projects/swift.md")
            ])
        }
    }

    @Test("Batch rolls back on partial failure")
    func moveBatchRollback() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        // First move is valid, second has nonexistent source -> should fail validation
        // and nothing should be moved
        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.moveNotes(moves: [
                .init(source: "notes/ideas/ml-stuff.md", destination: "notes/projects/ml.md"),
                .init(source: "notes/ghost.md", destination: "notes/projects/ghost.md")
            ])
        }

        // Source should still be at original location (validation failed before execution)
        #expect(FileManager.default.fileExists(atPath: root + "/notes/ideas/ml-stuff.md"))
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/projects/ml.md"))
    }
}
