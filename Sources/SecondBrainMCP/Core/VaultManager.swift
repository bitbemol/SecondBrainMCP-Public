import Foundation

/// Sandboxed note file I/O. Every method validates paths through PathValidator
/// before touching the filesystem. Actor because file operations must be serialized.
actor VaultManager {

    let config: ServerConfig

    enum VaultError: Error, CustomStringConvertible {
        case noteNotFound(String)
        case noteAlreadyExists(String)
        case directoryNotFound(String)
        case readFailed(String, underlying: String)
        case invalidMove(String)
        case invalidPath(String)
        case patchFailed(String)

        var description: String {
            switch self {
            case .noteNotFound(let path):
                return "Note not found: \(path)"
            case .noteAlreadyExists(let path):
                return "Note already exists: \(path)"
            case .directoryNotFound(let path):
                return "Directory not found: \(path)"
            case .readFailed(let path, let underlying):
                return "Failed to read \(path): \(underlying)"
            case .invalidMove(let reason):
                return "Invalid move: \(reason)"
            case .invalidPath(let reason):
                return "Invalid path: \(reason)"
            case .patchFailed(let reason):
                return "Patch failed: \(reason)"
            }
        }
    }

    struct PatchOperation: Sendable {
        let oldText: String
        let newText: String
    }

    struct MoveOperation: Sendable {
        let source: String
        let destination: String
    }

    struct NoteInfo: Sendable {
        let relativePath: String
        let title: String
        let tags: [String]
        let modifiedDate: Date
        let createdDate: Date?
    }

    struct NoteContent: Sendable {
        let relativePath: String
        let content: String
        let metadata: MarkdownParser.NoteMetadata
    }

    struct NoteMetadataResult: Sendable {
        let relativePath: String
        let title: String
        let tags: [String]
        let created: String?
        let modifiedDate: Date
        let wordCount: Int
        let links: [String]
    }

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Read Operations

    /// Read a note's full content and parsed metadata.
    func readNote(relativePath: String) throws -> NoteContent {
        guard relativePath.hasPrefix("notes/") else {
            throw VaultError.invalidPath("Path must be within notes/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw VaultError.noteNotFound(relativePath)
        }

        let content: String
        do {
            content = try String(contentsOfFile: resolved, encoding: .utf8)
        } catch {
            throw VaultError.readFailed(relativePath, underlying: error.localizedDescription)
        }

        let filename = (resolved as NSString).lastPathComponent
        let metadata = MarkdownParser.parse(content: content, filename: filename)

        return NoteContent(
            relativePath: relativePath,
            content: content,
            metadata: metadata
        )
    }

    /// List all notes in the vault, optionally scoped to a subdirectory.
    func listNotes(
        directory: String? = nil,
        recursive: Bool = true,
        tag: String? = nil
    ) throws -> [NoteInfo] {
        let baseDir: String
        if let directory {
            guard directory.hasPrefix("notes/") || directory == "notes" else {
                throw VaultError.invalidPath("Directory must be within notes/: \(directory)")
            }
            baseDir = try PathValidator.resolve(relativePath: directory, root: config.vaultPath)
        } else {
            baseDir = config.vaultPath + "/notes"
        }

        guard FileManager.default.fileExists(atPath: baseDir) else {
            // If notes/ doesn't exist yet, return empty
            return []
        }

        let fm = FileManager.default
        let allFiles: [String]

        if recursive {
            guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }
            allFiles = enumerator.compactMap { $0 as? String }
        } else {
            allFiles = (try? fm.contentsOfDirectory(atPath: baseDir)) ?? []
        }

        let allowedExts = config.allowedExtensions
        var results: [NoteInfo] = []

        for relativePart in allFiles {
            let ext = (relativePart as NSString).pathExtension.lowercased()
            guard allowedExts.contains(ext) else { continue }

            let fullPath = baseDir + "/" + relativePart
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            // Build the vault-relative path
            let vaultRelative: String
            if let directory {
                vaultRelative = directory + "/" + relativePart
            } else {
                vaultRelative = "notes/" + relativePart
            }

            // Read minimal metadata without loading full content into NoteInfo
            let attributes = try? fm.attributesOfItem(atPath: fullPath)
            let modDate = attributes?[.modificationDate] as? Date ?? Date()
            let createDate = attributes?[.creationDate] as? Date

            let content = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
            let filename = (fullPath as NSString).lastPathComponent
            let parsed = MarkdownParser.parse(content: content, filename: filename)

            // Filter by tag if specified
            if let tag = tag?.lowercased() {
                guard parsed.tags.contains(tag) else { continue }
            }

            results.append(NoteInfo(
                relativePath: vaultRelative,
                title: parsed.title,
                tags: parsed.tags,
                modifiedDate: modDate,
                createdDate: createDate
            ))
        }

        // Sort by modification date, newest first
        return results.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    /// Get metadata for a specific note without returning full content.
    func getNoteMetadata(relativePath: String) throws -> NoteMetadataResult {
        guard relativePath.hasPrefix("notes/") else {
            throw VaultError.invalidPath("Path must be within notes/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw VaultError.noteNotFound(relativePath)
        }

        let content = try String(contentsOfFile: resolved, encoding: .utf8)
        let filename = (resolved as NSString).lastPathComponent
        let parsed = MarkdownParser.parse(content: content, filename: filename)
        let links = MarkdownParser.extractLinks(from: content)

        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        let modDate = attributes?[.modificationDate] as? Date ?? Date()

        let wordCount = parsed.bodyContent
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count

        return NoteMetadataResult(
            relativePath: relativePath,
            title: parsed.title,
            tags: parsed.tags,
            created: parsed.created,
            modifiedDate: modDate,
            wordCount: wordCount,
            links: links
        )
    }

    // MARK: - Write Operations (Phase 3)

    /// Create a new note. Auto-generates frontmatter if content doesn't include it.
    func createNote(relativePath: String, content: String, tags: [String] = []) throws -> String {
        guard relativePath.hasPrefix("notes/") else {
            throw VaultError.invalidPath("Path must be within notes/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        guard !FileManager.default.fileExists(atPath: resolved) else {
            throw VaultError.noteAlreadyExists(relativePath)
        }

        // Ensure parent directory exists
        let parentDir = (resolved as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // Add frontmatter if not present
        var finalContent = content
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") {
            let filename = (resolved as NSString).lastPathComponent
            let title = MarkdownParser.titleFromFilename(filename)
            let frontmatter = MarkdownParser.generateFrontmatter(title: title, tags: tags)
            finalContent = frontmatter + content
        }

        try finalContent.write(toFile: resolved, atomically: true, encoding: .utf8)
        return "Created: \(relativePath)"
    }

    /// Update an existing note. Mode: "replace" (default) or "append".
    func updateNote(relativePath: String, content: String, mode: String = "replace") throws -> String {
        guard relativePath.hasPrefix("notes/") else {
            throw VaultError.invalidPath("Path must be within notes/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw VaultError.noteNotFound(relativePath)
        }

        if mode == "append" {
            let existing = try String(contentsOfFile: resolved, encoding: .utf8)
            let updated = existing + "\n" + content
            try updated.write(toFile: resolved, atomically: true, encoding: .utf8)
        } else {
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
        }

        return "Updated: \(relativePath) (mode: \(mode))"
    }

    /// Surgically edit specific parts of a note via find-and-replace patches.
    /// Each patch's oldText must appear exactly once. Patches are applied sequentially
    /// to an in-memory copy — the file is only written if all patches succeed.
    func patchNote(relativePath: String, patches: [PatchOperation]) throws -> String {
        guard relativePath.hasPrefix("notes/") else {
            throw VaultError.invalidPath("Path must be within notes/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw VaultError.noteNotFound(relativePath)
        }

        let content = try String(contentsOfFile: resolved, encoding: .utf8)

        guard !patches.isEmpty else {
            throw VaultError.patchFailed("No patches provided")
        }
        guard patches.count <= 20 else {
            throw VaultError.patchFailed("Too many patches: \(patches.count). Maximum is 20.")
        }

        var working = content
        var appliedCount = 0

        for (i, patch) in patches.enumerated() {
            if patch.oldText == patch.newText { continue }

            // Count occurrences
            var count = 0
            var searchStart = working.startIndex
            while let range = working.range(of: patch.oldText, range: searchStart..<working.endIndex) {
                count += 1
                searchStart = range.upperBound
            }

            if count == 0 {
                throw VaultError.patchFailed(
                    "Patch \(i + 1): text not found: \"\(patch.oldText.prefix(100))\""
                )
            }
            if count > 1 {
                throw VaultError.patchFailed(
                    "Patch \(i + 1): ambiguous — found \(count) occurrences of: \"\(patch.oldText.prefix(100))\". Provide more surrounding context to make it unique."
                )
            }

            guard let range = working.range(of: patch.oldText) else {
                throw VaultError.patchFailed("Patch \(i + 1): text not found: \"\(patch.oldText.prefix(100))\"")
            }
            working.replaceSubrange(range, with: patch.newText)
            appliedCount += 1
        }

        if appliedCount == 0 {
            return "No changes: all patches were no-ops"
        }

        try working.write(toFile: resolved, atomically: true, encoding: .utf8)
        return "Patched: \(relativePath) (\(appliedCount) patch(es) applied)"
    }

    // MARK: - Move Operations

    /// Move a note from one path to another within notes/.
    func moveNote(source: String, destination: String) throws -> String {
        let validated = try validateMove(source: source, destination: destination)

        // Create destination parent directory if needed
        let parentDir = (validated.dstPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // Execute the move
        if validated.isCaseOnlyRename {
            // macOS APFS/HFS+ is case-insensitive: moveItem fails or no-ops for case-only renames.
            // Two-step via temp file: Foo.md -> Foo.md.moving-uuid -> foo.md
            let tempPath = validated.srcPath + ".moving-\(UUID().uuidString)"
            try FileManager.default.moveItem(atPath: validated.srcPath, toPath: tempPath)
            do {
                try FileManager.default.moveItem(atPath: tempPath, toPath: validated.dstPath)
            } catch {
                // Rollback: move temp back to source
                try? FileManager.default.moveItem(atPath: tempPath, toPath: validated.srcPath)
                throw error
            }
        } else {
            try FileManager.default.moveItem(atPath: validated.srcPath, toPath: validated.dstPath)
        }

        // Clean up empty parent directories left behind
        cleanupEmptyDirectories(from: validated.srcPath)

        return "Moved: \(source) -> \(destination)"
    }

    /// Move multiple notes atomically. Validates all moves first, then executes.
    /// Maximum 20 moves per batch. Rolls back on partial failure.
    func moveNotes(moves: [MoveOperation]) throws -> String {
        guard !moves.isEmpty else {
            throw VaultError.invalidMove("No moves specified")
        }
        guard moves.count <= 20 else {
            throw VaultError.invalidMove("Too many moves: \(moves.count). Maximum is 20 per batch.")
        }

        // Check for duplicate sources (can't move the same file twice)
        var sourcesSeen = Set<String>()
        for move in moves {
            let key = move.source.lowercased()
            guard sourcesSeen.insert(key).inserted else {
                throw VaultError.invalidMove("Duplicate source: \(move.source)")
            }
        }

        // Check for duplicate destinations
        var destsSeen = Set<String>()
        for move in moves {
            let key = move.destination.lowercased()
            guard destsSeen.insert(key).inserted else {
                throw VaultError.invalidMove("Duplicate destination: \(move.destination)")
            }
        }

        // Reject source/destination overlap (a destination is also a source in the batch).
        // This prevents ordering-dependent data loss (e.g., A->B and B->C).
        let overlap = sourcesSeen.intersection(destsSeen)
        if !overlap.isEmpty {
            throw VaultError.invalidMove(
                "A destination path is also a source path in this batch. "
                + "Split into separate move_notes calls to avoid ordering-dependent data loss."
            )
        }

        // Validate ALL moves upfront
        var validated: [(v: ValidatedMove, op: MoveOperation)] = []
        for move in moves {
            let v = try validateMove(source: move.source, destination: move.destination)
            validated.append((v, move))
        }

        // Execute all moves
        var completed: [(srcPath: String, dstPath: String)] = []
        do {
            for (v, _) in validated {
                let parentDir = (v.dstPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

                if v.isCaseOnlyRename {
                    let tempPath = v.srcPath + ".moving-\(UUID().uuidString)"
                    try FileManager.default.moveItem(atPath: v.srcPath, toPath: tempPath)
                    do {
                        try FileManager.default.moveItem(atPath: tempPath, toPath: v.dstPath)
                    } catch {
                        try? FileManager.default.moveItem(atPath: tempPath, toPath: v.srcPath)
                        throw error
                    }
                } else {
                    try FileManager.default.moveItem(atPath: v.srcPath, toPath: v.dstPath)
                }
                completed.append((v.srcPath, v.dstPath))
            }
        } catch {
            // Rollback all completed moves in reverse order
            for done in completed.reversed() {
                try? FileManager.default.moveItem(atPath: done.dstPath, toPath: done.srcPath)
            }
            throw VaultError.invalidMove(
                "Batch move failed after \(completed.count)/\(moves.count) moves (rolled back): \(error)"
            )
        }

        // Clean up empty parent directories for all sources
        for (v, _) in validated {
            cleanupEmptyDirectories(from: v.srcPath)
        }

        var lines = ["Moved \(moves.count) note(s):"]
        for move in moves {
            lines.append("  \(move.source) -> \(move.destination)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Move Validation

    private struct ValidatedMove {
        let srcPath: String
        let dstPath: String
        let isCaseOnlyRename: Bool
    }

    /// Validate a single move: both paths in notes/, source exists, destination safe.
    private func validateMove(source: String, destination: String) throws -> ValidatedMove {
        // Both must be within notes/
        guard source.hasPrefix("notes/") else {
            throw VaultError.invalidMove("Source must be within notes/: \(source)")
        }
        guard destination.hasPrefix("notes/") else {
            throw VaultError.invalidMove("Destination must be within notes/: \(destination)")
        }

        // Reject identical paths before any filesystem work
        if source == destination {
            throw VaultError.invalidMove("Source and destination are the same: \(source)")
        }

        // Security + extension validation via PathValidator
        let srcResolved = try PathValidator.resolve(
            relativePath: source,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )
        _ = try PathValidator.resolve(
            relativePath: destination,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        // Source must exist
        guard FileManager.default.fileExists(atPath: srcResolved) else {
            throw VaultError.noteNotFound(source)
        }

        // Source must be a file, not a directory
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: srcResolved, isDirectory: &isDir)
        guard !isDir.boolValue else {
            throw VaultError.invalidMove("Source is a directory, not a note: \(source)")
        }

        // Construct destination path preserving intended casing
        let dstPath = URL(fileURLWithPath: config.vaultPath)
            .appendingPathComponent(destination).path

        // Detect case-only rename (same path, different casing — macOS APFS/HFS+)
        let isCaseOnly = source.lowercased() == destination.lowercased()

        // Destination must not already exist (unless case-only rename of the same file)
        if !isCaseOnly && FileManager.default.fileExists(atPath: dstPath) {
            throw VaultError.noteAlreadyExists(destination)
        }

        return ValidatedMove(srcPath: srcResolved, dstPath: dstPath, isCaseOnlyRename: isCaseOnly)
    }

    /// Remove empty parent directories up to notes/.
    private func cleanupEmptyDirectories(from filePath: String) {
        let notesDir = config.vaultPath + "/notes"
        var dir = (filePath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        while dir != notesDir && dir.hasPrefix(notesDir + "/") {
            let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? ["placeholder"]
            // Ignore .DS_Store when checking if directory is empty
            let meaningful = contents.filter { $0 != ".DS_Store" }
            if meaningful.isEmpty {
                try? fm.removeItem(atPath: dir)
                dir = (dir as NSString).deletingLastPathComponent
            } else {
                break
            }
        }
    }

    // MARK: - Delete Operations

    /// Soft-delete a note by moving it to .trash/.
    func deleteNote(relativePath: String) throws -> String {
        guard relativePath.hasPrefix("notes/") else {
            throw VaultError.invalidPath("Path must be within notes/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: config.vaultPath,
            allowedExtensions: config.allowedExtensions
        )

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw VaultError.noteNotFound(relativePath)
        }

        // Create trash directory if needed
        let trashDir = config.vaultPath + "/.trash"
        try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)

        // Generate timestamped trash filename
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = (resolved as NSString).lastPathComponent
        let trashPath = trashDir + "/\(timestamp)_\(filename)"

        try FileManager.default.moveItem(atPath: resolved, toPath: trashPath)
        return "Deleted: \(relativePath) → .trash/\(timestamp)_\(filename)"
    }
}
