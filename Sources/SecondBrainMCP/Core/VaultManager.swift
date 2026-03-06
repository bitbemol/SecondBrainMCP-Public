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
            }
        }
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

    /// Soft-delete a note by moving it to .trash/.
    func deleteNote(relativePath: String) throws -> String {
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
