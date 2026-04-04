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

        // Path traversal is now caught by the notes/ prefix guard before PathValidator
        await #expect(throws: VaultManager.VaultError.self) {
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

// MARK: - Boundary Enforcement Tests
//
// Security invariant: all note operations MUST only access notes/.
// All reference operations MUST only access references/.
// These tests document and enforce that boundary for every operation.

@Suite("VaultManager — Note Boundary Enforcement")
struct VaultManagerNoteBoundaryTests {

    private func makeTestVault() throws -> (String, ServerConfig) {
        let root = NSTemporaryDirectory() + "VaultBoundaryTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)

        try """
        ---
        title: Existing Note
        tags: [test]
        ---

        Some content.
        """.write(toFile: root + "/notes/projects/existing.md", atomically: true, encoding: .utf8)

        // Create a file outside notes/ to prove reads are blocked
        try "# Outside Notes".write(
            toFile: root + "/references/sneaky.md", atomically: true, encoding: .utf8
        )
        try "# Vault Root File".write(
            toFile: root + "/root-file.md", atomically: true, encoding: .utf8
        )

        let config = try ServerConfig.parse(arguments: ["binary", "--vault", root])
        return (root, config)
    }

    // MARK: - read_note

    @Test("read_note within notes/ succeeds")
    func readNoteInside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let note = try await vault.readNote(relativePath: "notes/projects/existing.md")
        #expect(note.content.contains("Some content"))
    }

    @Test("read_note outside notes/ is rejected")
    func readNoteOutside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.readNote(relativePath: "references/sneaky.md")
        }
    }

    @Test("read_note at vault root is rejected")
    func readNoteAtRoot() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.readNote(relativePath: "root-file.md")
        }
    }

    @Test("read_note with arbitrary path is rejected")
    func readNoteArbitraryPath() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.readNote(relativePath: "apps/Xcode/something.md")
        }
    }

    // MARK: - list_notes

    @Test("list_notes with no directory succeeds (defaults to notes/)")
    func listNotesDefault() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes()
        #expect(!notes.isEmpty)
    }

    @Test("list_notes scoped to notes/ subdirectory succeeds")
    func listNotesSubdir() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes(directory: "notes/projects")
        #expect(!notes.isEmpty)
    }

    @Test("list_notes scoped to 'notes' (no trailing slash) succeeds")
    func listNotesExact() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let notes = try await vault.listNotes(directory: "notes")
        #expect(!notes.isEmpty)
    }

    @Test("list_notes scoped to references/ is rejected")
    func listNotesReferences() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.listNotes(directory: "references")
        }
    }

    @Test("list_notes scoped to arbitrary directory is rejected")
    func listNotesArbitraryDir() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.listNotes(directory: "apps/Xcode")
        }
    }

    // MARK: - get_note_metadata

    @Test("get_note_metadata within notes/ succeeds")
    func getMetadataInside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let meta = try await vault.getNoteMetadata(relativePath: "notes/projects/existing.md")
        #expect(meta.title == "Existing Note")
    }

    @Test("get_note_metadata outside notes/ is rejected")
    func getMetadataOutside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.getNoteMetadata(relativePath: "references/sneaky.md")
        }
    }

    @Test("get_note_metadata at vault root is rejected")
    func getMetadataAtRoot() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.getNoteMetadata(relativePath: "root-file.md")
        }
    }

    // MARK: - create_note

    @Test("create_note within notes/ succeeds")
    func createNoteInside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.createNote(relativePath: "notes/new.md", content: "# New")
        #expect(result.contains("Created"))
    }

    @Test("create_note outside notes/ is rejected")
    func createNoteOutside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.createNote(relativePath: "apps/Xcode/foo.md", content: "# Foo")
        }
    }

    @Test("create_note in references/ is rejected")
    func createNoteInReferences() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.createNote(relativePath: "references/sneaky.md", content: "# Nope")
        }
    }

    @Test("create_note at vault root is rejected")
    func createNoteAtRoot() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.createNote(relativePath: "root-level.md", content: "# Root")
        }
    }

    // MARK: - update_note

    @Test("update_note within notes/ succeeds")
    func updateNoteInside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.updateNote(
            relativePath: "notes/projects/existing.md", content: "# Updated"
        )
        #expect(result.contains("Updated"))
    }

    @Test("update_note outside notes/ is rejected")
    func updateNoteOutside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.updateNote(relativePath: "apps/Xcode/foo.md", content: "# Foo")
        }
    }

    @Test("update_note in references/ is rejected")
    func updateNoteInReferences() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.updateNote(relativePath: "references/sneaky.md", content: "# Nope")
        }
    }

    // MARK: - delete_note

    @Test("delete_note within notes/ succeeds")
    func deleteNoteInside() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.deleteNote(relativePath: "notes/projects/existing.md")
        #expect(result.contains("Deleted"))
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/projects/existing.md"))
    }

    @Test("delete_note outside notes/ is rejected")
    func deleteNoteOutside() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.deleteNote(relativePath: "references/sneaky.md")
        }
    }

    @Test("delete_note at vault root is rejected")
    func deleteNoteAtRoot() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.deleteNote(relativePath: "root-file.md")
        }
    }
}

@Suite("VaultManager — Patch Operations")
struct VaultManagerPatchTests {

    private func makeTestVault() throws -> (String, ServerConfig) {
        let root = NSTemporaryDirectory() + "VaultPatchTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)

        let note = """
        ---
        title: Project Plan
        tags: [project, planning]
        ---

        # Project Plan

        ## Status
        In progress since March.

        ## Architecture
        Using MVVM pattern with coordinator navigation.

        ## TODO
        - Fix the login bug
        - Add unit tests
        - Update documentation
        """
        try note.write(toFile: root + "/notes/project.md", atomically: true, encoding: .utf8)

        let config = try ServerConfig.parse(arguments: ["binary", "--vault", root])
        return (root, config)
    }

    @Test("Single patch replaces text")
    func singlePatch() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [.init(oldText: "In progress since March.", newText: "Completed on 2026-04-03.")]
        )

        #expect(result.contains("Patched"))
        let content = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(content.contains("Completed on 2026-04-03."))
        #expect(!content.contains("In progress since March."))
    }

    @Test("Multiple patches applied sequentially")
    func multiplePatches() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [
                .init(oldText: "In progress since March.", newText: "Done."),
                .init(oldText: "- Fix the login bug\n", newText: "")
            ]
        )

        #expect(result.contains("2 patch(es) applied"))
        let content = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(content.contains("Done."))
        #expect(!content.contains("Fix the login bug"))
    }

    @Test("Patch with empty new_text deletes text")
    func deleteViaPatch() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        _ = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [.init(oldText: "- Fix the login bug\n", newText: "")]
        )

        let content = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(!content.contains("Fix the login bug"))
        #expect(content.contains("- Add unit tests"))
    }

    @Test("Patch inserts after anchor")
    func insertAfterAnchor() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        _ = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [.init(oldText: "## TODO", newText: "## TODO\n- NEW TASK")]
        )

        let content = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(content.contains("## TODO\n- NEW TASK"))
    }

    @Test("Patch not found throws error")
    func patchNotFound() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)
        let original = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(
                relativePath: "notes/project.md",
                patches: [.init(oldText: "this text does not exist anywhere", newText: "replacement")]
            )
        }

        let after = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(after == original)
    }

    @Test("Ambiguous patch throws error")
    func ambiguousPatch() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        // Write a note with duplicate text
        let dupeNote = "AAA\nBBB\nAAA\n"
        try dupeNote.write(toFile: root + "/notes/dupe.md", atomically: true, encoding: .utf8)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(
                relativePath: "notes/dupe.md",
                patches: [.init(oldText: "AAA", newText: "CCC")]
            )
        }

        let after = try String(contentsOfFile: root + "/notes/dupe.md", encoding: .utf8)
        #expect(after == dupeNote)
    }

    @Test("Failed patch leaves file unchanged")
    func failedPatchNoSideEffect() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)
        let original = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(
                relativePath: "notes/project.md",
                patches: [
                    .init(oldText: "In progress since March.", newText: "Done."),
                    .init(oldText: "THIS DOES NOT EXIST", newText: "whatever")
                ]
            )
        }

        let after = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(after == original)
    }

    @Test("No-op patches skip without writing")
    func noOpPatches() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [
                .init(oldText: "In progress since March.", newText: "In progress since March."),
                .init(oldText: "## TODO", newText: "## TODO")
            ]
        )

        #expect(result.hasPrefix("No changes"))
    }

    @Test("Empty patches array throws")
    func emptyPatches() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(relativePath: "notes/project.md", patches: [])
        }
    }

    @Test("Exceeding 20 patches throws")
    func tooManyPatches() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let patches = (0..<21).map {
            VaultManager.PatchOperation(oldText: "old\($0)", newText: "new\($0)")
        }

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(relativePath: "notes/project.md", patches: patches)
        }
    }

    @Test("Patch outside notes/ is rejected")
    func patchOutsideNotes() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(
                relativePath: "references/something.md",
                patches: [.init(oldText: "a", newText: "b")]
            )
        }
    }

    @Test("Patch on nonexistent note throws")
    func patchNonexistent() async throws {
        let (_, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        await #expect(throws: VaultManager.VaultError.self) {
            try await vault.patchNote(
                relativePath: "notes/ghost.md",
                patches: [.init(oldText: "a", newText: "b")]
            )
        }
    }

    @Test("Patch modifies frontmatter")
    func patchFrontmatter() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        _ = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [.init(oldText: "tags: [project, planning]", newText: "tags: [project, planning, completed]")]
        )

        let content = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(content.contains("tags: [project, planning, completed]"))
    }

    @Test("Sequential patches see earlier changes")
    func sequentialVisibility() async throws {
        let (root, config) = try makeTestVault()
        let vault = VaultManager(config: config)

        let result = try await vault.patchNote(
            relativePath: "notes/project.md",
            patches: [
                .init(oldText: "MVVM", newText: "VIPER"),
                .init(oldText: "Using VIPER pattern", newText: "Using VIPER architecture")
            ]
        )

        #expect(result.contains("2 patch(es) applied"))
        let content = try String(contentsOfFile: root + "/notes/project.md", encoding: .utf8)
        #expect(content.contains("Using VIPER architecture"))
        #expect(!content.contains("MVVM"))
    }
}

@Suite("ReferenceManager — Reference Boundary Enforcement")
struct ReferenceManagerBoundaryTests {

    private func makeTestVault() throws -> (String, ReferenceManager) {
        let root = NSTemporaryDirectory() + "RefBoundaryTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references/Papers", withIntermediateDirectories: true)

        return (root, ReferenceManager(vaultPath: root))
    }

    // MARK: - list_references

    @Test("list_references with no directory succeeds")
    func listReferencesDefault() throws {
        let (_, refManager) = try makeTestVault()

        // Returns empty (no PDFs in test vault), but doesn't throw
        let refs = try refManager.listReferences()
        #expect(refs.isEmpty)
    }

    @Test("list_references scoped to subdirectory succeeds")
    func listReferencesSubdir() throws {
        let (_, refManager) = try makeTestVault()

        let refs = try refManager.listReferences(directory: "Papers")
        #expect(refs.isEmpty)
    }

    @Test("list_references with path traversal is rejected")
    func listReferencesTraversal() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.listReferences(directory: "../notes")
        }
    }

    @Test("list_references with nested traversal is rejected")
    func listReferencesNestedTraversal() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.listReferences(directory: "Papers/../../notes")
        }
    }

    // MARK: - read_reference

    @Test("read_reference outside references/ is rejected")
    func readReferenceOutside() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.readReference(relativePath: "notes/something.pdf")
        }
    }

    @Test("read_reference at vault root is rejected")
    func readReferenceAtRoot() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.readReference(relativePath: "some-file.pdf")
        }
    }

    @Test("read_reference with arbitrary path is rejected")
    func readReferenceArbitraryPath() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.readReference(relativePath: "apps/secret.pdf")
        }
    }

    // MARK: - get_reference_metadata

    @Test("get_reference_metadata outside references/ is rejected")
    func getMetadataOutside() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.getMetadata(relativePath: "notes/something.pdf")
        }
    }

    @Test("get_reference_metadata at vault root is rejected")
    func getMetadataAtRoot() throws {
        let (_, refManager) = try makeTestVault()

        #expect(throws: ReferenceManager.ReferenceError.self) {
            try refManager.getMetadata(relativePath: "root.pdf")
        }
    }
}
