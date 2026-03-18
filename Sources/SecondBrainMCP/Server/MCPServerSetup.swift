import Foundation
import MCP

/// Boot the MCP server, register all tool and resource handlers, start transport.
///
/// ## Startup Flow
/// 1. Create actors (VaultManager, ReferenceManager, AuditLogger) and SearchEngine
/// 2. Register all MCP handlers
/// 3. Start StdioTransport — server is now accepting client connections
///
/// No background indexing. Search uses on-demand disk grep (SSD-fast, zero memory).
struct MCPServerSetup {

    static func start(config: ServerConfig, gitManager: GitManager) async throws {
        // Migrate internal data (cache, logs, locks) from vault to ~/Library/Application Support/
        // so iCloud doesn't create corrupted duplicate directories.
        DataPaths.migrateFromVaultIfNeeded(vaultPath: config.vaultPath)

        let customInstructions = Self.loadCustomInstructions(vaultPath: config.vaultPath)
        let server = Server(
            name: "SecondBrainMCP",
            version: "1.0.0",
            instructions: """
            This is a personal knowledge vault with Markdown notes and PDF references. \
            Use the note tools to search, read, and manage notes. \
            Use the reference tools to search and read PDF books. \
            All note writes are automatically committed to git. \
            Paths are always relative to the vault root (e.g. "notes/projects/app.md").
            """ + (customInstructions.map { "\n\n" + $0 } ?? ""),
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        let vaultManager = VaultManager(config: config)
        let referenceManager = ReferenceManager(vaultPath: config.vaultPath)
        let searchEngine = SearchEngine(vaultPath: config.vaultPath)
        let auditLogger = AuditLogger(vaultPath: config.vaultPath)

        // ── Register handlers FIRST (before index is built) ──
        // This allows the server to accept connections immediately.

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.buildToolList(config: config))
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await Self.handleToolCall(
                params: params,
                vaultManager: vaultManager,
                referenceManager: referenceManager,
                searchEngine: searchEngine,
                gitManager: gitManager,
                config: config,
                auditLogger: auditLogger
            )
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [
                Resource(
                    name: "Vault Index",
                    uri: "secondbrain://index",
                    description: "Full vault index: all note paths, titles, and tags",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "Recent Notes",
                    uri: "secondbrain://recent",
                    description: "Notes modified in the last 7 days",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "Tags",
                    uri: "secondbrain://tags",
                    description: "All unique tags across the vault with note counts",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "References Index",
                    uri: "secondbrain://references",
                    description: "All PDF references: paths, titles, authors, page counts",
                    mimeType: "application/json"
                )
            ])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            switch params.uri {
            case "secondbrain://index":
                return try await Self.handleIndexResource(vaultManager: vaultManager)
            case "secondbrain://recent":
                return try await Self.handleRecentResource(vaultManager: vaultManager)
            case "secondbrain://tags":
                return try await Self.handleTagsResource(vaultManager: vaultManager)
            case "secondbrain://references":
                return Self.handleReferencesResource(referenceManager: referenceManager)
            default:
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
        }

        // ── Start transport — server is now live ──
        let transport = StdioTransport()
        try await server.start(transport: transport)
        log("MCP server started, accepting connections")

        // ── Background: build lightweight cache for uncached PDFs ──
        // Caches metadata, page labels, search text + outline (TOC for long PDFs, full text for short ones).
        // Search works immediately using whatever cache exists on disk.
        Task {
            // Let the MCP handshake complete before heavy work
            try? await Task.sleep(for: .seconds(1))

            let stepStart = ContinuousClock.now
            referenceManager.ensureCacheExists()
            log("background: PDF cache check: \(stepStart.duration(to: .now))")
        }

        await server.waitUntilCompleted()
    }

    // MARK: - Custom Instructions

    private static func loadCustomInstructions(vaultPath: String) -> String? {
        let url = URL(fileURLWithPath: vaultPath).appendingPathComponent("INSTRUCTIONS.md")
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool Definitions

    private static func buildToolList(config: ServerConfig) -> [Tool] {
        var tools: [Tool] = []

        // -- Read tools (always registered) --

        tools.append(Tool(
            name: "read_note",
            description: "Read the full content of a specific note",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path from vault root (e.g. notes/projects/app.md)")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "list_notes",
            description: "List all notes in the vault, optionally filtered by directory or tag",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Subdirectory to list (default: notes/)")
                    ]),
                    "recursive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include subdirectories (default: true)")
                    ]),
                    "tag": .object([
                        "type": .string("string"),
                        "description": .string("Filter by frontmatter tag")
                    ])
                ])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "get_note_metadata",
            description: "Get structured metadata for a note without reading full content",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to the note")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "search_notes",
            description: "Full-text search across all notes by content and title",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search terms")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Limit results (default: 20)")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        // -- Write tools (only if not read-only) -- Phase 3
        if !config.readOnly {
            tools.append(Tool(
                name: "create_note",
                description: "Create a new Markdown note with optional tags. Auto-generates frontmatter.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path for the new file (e.g. notes/ideas/new-idea.md)")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("Markdown content")
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Tags to add to frontmatter")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("content")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "update_note",
                description: "Update an existing note. Supports full replace or append mode.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("New content")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("replace"), .string("append")]),
                            "description": .string("replace (default) or append")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("content")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "move_note",
                description: "Move/rename a note within notes/. Preserves git history. Cannot overwrite existing notes.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Current relative path (e.g. notes/ideas/ml-stuff.md)")
                        ]),
                        "destination": .object([
                            "type": .string("string"),
                            "description": .string("New relative path (e.g. notes/projects/machine-learning.md)")
                        ])
                    ]),
                    "required": .array([.string("source"), .string("destination")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "move_notes",
                description: "Batch move/rename multiple notes atomically. All-or-nothing: validates all moves first, rolls back on failure. Max 20 moves per call.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "moves": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "source": .object([
                                        "type": .string("string"),
                                        "description": .string("Current relative path")
                                    ]),
                                    "destination": .object([
                                        "type": .string("string"),
                                        "description": .string("New relative path")
                                    ])
                                ]),
                                "required": .array([.string("source"), .string("destination")])
                            ]),
                            "description": .string("Array of {source, destination} pairs. Maximum 20 moves per call.")
                        ])
                    ]),
                    "required": .array([.string("moves")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "delete_note",
                description: "Soft-delete a note by moving it to .trash/ (recoverable)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))
        }

        // -- Git history tools (only if not read-only) -- Phase 4
        if !config.readOnly {
            tools.append(Tool(
                name: "note_history",
                description: "Show git commit history for a specific note",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ]),
                        "max_entries": .object([
                            "type": .string("integer"),
                            "description": .string("Limit history entries (default: 10)")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "revert_note",
                description: "Revert a note to a previous git commit (creates a new commit)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ]),
                        "commit": .object([
                            "type": .string("string"),
                            "description": .string("Commit hash to revert to")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("commit")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "vault_changelog",
                description: "Show recent changes across the entire vault",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_entries": .object([
                            "type": .string("integer"),
                            "description": .string("Limit entries (default: 20)")
                        ]),
                        "since": .object([
                            "type": .string("string"),
                            "description": .string("ISO date to filter from (e.g. 2026-02-22)")
                        ])
                    ])
                ]),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))
        }

        // -- Reference tools (always read-only) -- Phase 5
        tools.append(Tool(
            name: "list_references",
            description: "List all PDF files in the reference library",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Subdirectory within references/ (default: all)")
                    ])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "read_reference",
            description: "Read PDF pages. Returns extracted text (for accurate reading) + JPEG images (for diagrams/figures/equations). Also returns PDF outline (table of contents with chapter names and page numbers) and page labels. Use 'query' to search within a specific PDF (searches full document text). Use 'book_page' to navigate by printed page number.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Relative path to PDF (e.g. references/book.pdf)")]),
                    "page": .object(["type": .string("integer"), "description": .string("PDF page number (1-indexed, physical page in the PDF file)")]),
                    "book_page": .object(["type": .string("string"), "description": .string("Navigate by printed page number (e.g. '42', 'xii'). Uses page labels embedded in the PDF.")]),
                    "page_range": .object(["type": .string("string"), "description": .string("Page range like '10-25'")]),
                    "query": .object(["type": .string("string"), "description": .string("Search within the PDF for text, returns matching pages as images")]),
                    "max_pages": .object(["type": .string("integer"), "description": .string("Limit pages returned (default: 5). Each page is a JPEG image.")])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "search_references",
            description: "Full-text search across all PDF documents in the reference library",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search terms")]),
                    "max_results": .object(["type": .string("integer"), "description": .string("Limit results (default: 10)")]),
                    "max_per_document": .object(["type": .string("integer"), "description": .string("Max results per PDF (default: 3). Set higher to see more pages from each book.")])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "get_reference_metadata",
            description: "Get metadata about a PDF (title, author, pages, size) without reading content",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Relative path to the PDF")])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        return tools
    }

    // MARK: - Tool Dispatch

    private static func handleToolCall(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        referenceManager: ReferenceManager,
        searchEngine: SearchEngine,
        gitManager: GitManager?,
        config: ServerConfig,
        auditLogger: AuditLogger
    ) async throws -> CallTool.Result {
        // Note: searchEngine is a value type (struct), passed through for search handlers.
        // Audit log every tool call
        let auditOp: AuditLogger.Operation? = switch params.name {
        case "read_note": .read
        case "list_notes": .read
        case "get_note_metadata": .read
        case "search_notes": .search
        case "create_note": .create
        case "update_note": .update
        case "move_note": .move
        case "move_notes": .move
        case "delete_note": .delete
        case "note_history": .read
        case "revert_note": .update
        case "vault_changelog": .read
        case "list_references": .listRef
        case "read_reference": .readRef
        case "search_references": .searchRef
        case "get_reference_metadata": .metadataRef
        default: nil
        }
        if let op = auditOp {
            let path = params.arguments?["path"]?.stringValue
            await auditLogger.log(operation: op, path: path, details: params.name)
        }

        switch params.name {
        // Note tools
        case "read_note":
            return try await handleReadNote(params: params, vaultManager: vaultManager)
        case "list_notes":
            return try await handleListNotes(params: params, vaultManager: vaultManager)
        case "get_note_metadata":
            return try await handleGetNoteMetadata(params: params, vaultManager: vaultManager)
        case "search_notes":
            return handleSearchNotes(params: params, searchEngine: searchEngine)
        case "create_note":
            return try await handleCreateNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        case "update_note":
            return try await handleUpdateNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        case "move_note":
            return try await handleMoveNote(params: params, vaultManager: vaultManager, gitManager: gitManager, auditLogger: auditLogger)
        case "move_notes":
            return try await handleMoveNotes(params: params, vaultManager: vaultManager, gitManager: gitManager, auditLogger: auditLogger)
        case "delete_note":
            return try await handleDeleteNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        // Git tools
        case "note_history":
            return await handleNoteHistory(params: params, gitManager: gitManager)
        case "revert_note":
            return try await handleRevertNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        case "vault_changelog":
            return await handleVaultChangelog(params: params, gitManager: gitManager)
        // Reference tools
        case "list_references":
            return handleListReferences(params: params, referenceManager: referenceManager)
        case "read_reference":
            return await handleReadReference(params: params, referenceManager: referenceManager)
        case "search_references":
            return handleSearchReferences(params: params, searchEngine: searchEngine)
        case "get_reference_metadata":
            return handleGetReferenceMetadata(params: params, referenceManager: referenceManager)
        default:
            return CallTool.Result(
                content: [.text("Unknown tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Tool Handlers

    private static func handleReadNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text("Missing required parameter: path")],
                isError: true
            )
        }

        do {
            let note = try await vaultManager.readNote(relativePath: path)
            return CallTool.Result(
                content: [.text(note.content)]
            )
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    private static func handleListNotes(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        let directory = params.arguments?["directory"]?.stringValue
        let recursive = params.arguments?["recursive"]?.boolValue ?? true
        let tag = params.arguments?["tag"]?.stringValue

        do {
            let notes = try await vaultManager.listNotes(
                directory: directory,
                recursive: recursive,
                tag: tag
            )

            if notes.isEmpty {
                return CallTool.Result(
                    content: [.text("No notes found.")]
                )
            }

            let formatter = ISO8601DateFormatter()
            var lines: [String] = ["Found \(notes.count) note(s):", ""]

            for note in notes {
                let dateStr = formatter.string(from: note.modifiedDate)
                let tagStr = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
                lines.append("- **\(note.title)**\(tagStr)")
                lines.append("  Path: `\(note.relativePath)` | Modified: \(dateStr)")
            }

            return CallTool.Result(
                content: [.text(lines.joined(separator: "\n"))]
            )
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    private static func handleGetNoteMetadata(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text("Missing required parameter: path")],
                isError: true
            )
        }

        do {
            let meta = try await vaultManager.getNoteMetadata(relativePath: path)
            let formatter = ISO8601DateFormatter()

            var info: [String] = [
                "Title: \(meta.title)",
                "Path: \(meta.relativePath)",
                "Tags: \(meta.tags.isEmpty ? "(none)" : meta.tags.joined(separator: ", "))",
                "Created: \(meta.created ?? "unknown")",
                "Modified: \(formatter.string(from: meta.modifiedDate))",
                "Word count: \(meta.wordCount)"
            ]

            if !meta.links.isEmpty {
                info.append("Links: \(meta.links.joined(separator: ", "))")
            }

            return CallTool.Result(
                content: [.text(info.joined(separator: "\n"))]
            )
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    // MARK: - Search Handler (Phase 2)

    private static func handleSearchNotes(
        params: CallTool.Parameters,
        searchEngine: SearchEngine
    ) -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
            return CallTool.Result(
                content: [.text("Missing required parameter: query")],
                isError: true
            )
        }

        let maxResults = params.arguments?["max_results"]?.intValue ?? 20

        let results = searchEngine.searchNotes(
            query: query,
            maxResults: maxResults
        )

        if results.isEmpty {
            return CallTool.Result(content: [.text("No notes found matching '\(query)'.")])
        }

        var lines: [String] = ["Found \(results.count) result(s) for '\(query)':", ""]
        for result in results {
            lines.append("- **\(result.title)** (score: \(String(format: "%.2f", result.score)))")
            lines.append("  Path: `\(result.path)`")
            lines.append("  \(result.snippet)")
            lines.append("")
        }

        return CallTool.Result(
            content: [.text(lines.joined(separator: "\n"))]
        )
    }

    // MARK: - Write Handlers (Phase 3)

    private static func handleCreateNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue,
              let content = params.arguments?["content"]?.stringValue else {
            return CallTool.Result(
                content: [.text("Missing required parameters: path, content")],
                isError: true
            )
        }

        let tags: [String] = params.arguments?["tags"]?.arrayValue?
            .compactMap(\.stringValue) ?? []

        do {
            let result = try await vaultManager.createNote(relativePath: path, content: content, tags: tags)

            // Git commit
            if let git = gitManager {
                try? await git.commitChange(
                    files: [path],
                    message: "[SecondBrainMCP] Created: \(path)"
                )
            }

            return CallTool.Result(
                content: [.text(result)]
            )
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    private static func handleUpdateNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue,
              let content = params.arguments?["content"]?.stringValue else {
            return CallTool.Result(
                content: [.text("Missing required parameters: path, content")],
                isError: true
            )
        }

        let mode = params.arguments?["mode"]?.stringValue ?? "replace"

        do {
            let result = try await vaultManager.updateNote(relativePath: path, content: content, mode: mode)

            // Git commit
            if let git = gitManager {
                let modeStr = mode == "append" ? " (append)" : ""
                try? await git.commitChange(
                    files: [path],
                    message: "[SecondBrainMCP] Updated: \(path)\(modeStr)"
                )
            }

            return CallTool.Result(
                content: [.text(result)]
            )
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    private static func handleDeleteNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text("Missing required parameter: path")],
                isError: true
            )
        }

        do {
            let result = try await vaultManager.deleteNote(relativePath: path)

            // Git commit — use commitDeletion to handle case-insensitive filesystems
            if let git = gitManager {
                try? await git.commitDeletion(
                    path: path,
                    message: "[SecondBrainMCP] Deleted: \(path)"
                )
            }

            return CallTool.Result(
                content: [.text(result)]
            )
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    // MARK: - Move Handlers

    private static func handleMoveNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?,
        auditLogger: AuditLogger
    ) async throws -> CallTool.Result {
        guard let source = params.arguments?["source"]?.stringValue,
              let destination = params.arguments?["destination"]?.stringValue else {
            return CallTool.Result(
                content: [.text("Missing required parameters: source, destination")],
                isError: true
            )
        }

        do {
            let result = try await vaultManager.moveNote(source: source, destination: destination)

            // Git commit
            if let git = gitManager {
                try? await git.commitMoves(
                    moves: [(source: source, destination: destination)],
                    message: "[SecondBrainMCP] Moved: \(source) to \(destination)"
                )
            }

            await auditLogger.log(operation: .move, path: source, details: "-> \(destination)")

            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    private static func handleMoveNotes(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?,
        auditLogger: AuditLogger
    ) async throws -> CallTool.Result {
        guard let movesArray = params.arguments?["moves"]?.arrayValue else {
            return CallTool.Result(
                content: [.text("Missing required parameter: moves (array of {source, destination})")],
                isError: true
            )
        }

        // Parse the moves array
        var moves: [VaultManager.MoveOperation] = []
        for (index, item) in movesArray.enumerated() {
            guard let source = item.objectValue?["source"]?.stringValue,
                  let destination = item.objectValue?["destination"]?.stringValue else {
                return CallTool.Result(
                    content: [.text("Move at index \(index) missing source or destination")],
                    isError: true
                )
            }
            moves.append(VaultManager.MoveOperation(source: source, destination: destination))
        }

        do {
            let result = try await vaultManager.moveNotes(moves: moves)

            // Single git commit for the whole batch
            if let git = gitManager {
                let gitMoves = moves.map { (source: $0.source, destination: $0.destination) }
                try? await git.commitMoves(
                    moves: gitMoves,
                    message: "[SecondBrainMCP] Moved \(moves.count) notes"
                )
            }

            for move in moves {
                await auditLogger.log(operation: .move, path: move.source, details: "-> \(move.destination)")
            }

            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error)")],
                isError: true
            )
        }
    }

    // MARK: - Git History Handlers (Phase 4)

    private static func handleNoteHistory(
        params: CallTool.Parameters,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let git = gitManager else {
            return CallTool.Result(content: [.text("Git not available")], isError: true)
        }
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: path")], isError: true)
        }

        let maxEntries = params.arguments?["max_entries"]?.intValue ?? 10

        do {
            let entries = try await git.log(forFile: path, maxEntries: maxEntries)
            if entries.isEmpty {
                return CallTool.Result(content: [.text("No history found for \(path)")])
            }

            var lines: [String] = ["History for `\(path)` (\(entries.count) entries):", ""]
            for entry in entries {
                lines.append("- **\(entry.message)**")
                lines.append("  Commit: `\(entry.hash.prefix(8))` | Date: \(entry.date)")
            }

            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
        }
    }

    private static func handleRevertNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let git = gitManager else {
            return CallTool.Result(content: [.text("Git not available")], isError: true)
        }
        guard let path = params.arguments?["path"]?.stringValue,
              let commit = params.arguments?["commit"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameters: path, commit")], isError: true)
        }

        do {
            // Checkout the file from the specified commit
            try await git.checkoutFile(path: path, fromCommit: commit)

            // Commit the revert as a new commit
            try await git.commitChange(
                files: [path],
                message: "[SecondBrainMCP] Reverted: \(path) to \(String(commit.prefix(8)))"
            )

            return CallTool.Result(
                content: [.text("Reverted `\(path)` to commit `\(String(commit.prefix(8)))` and created new commit.")]
            )
        } catch {
            return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
        }
    }

    private static func handleVaultChangelog(
        params: CallTool.Parameters,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let git = gitManager else {
            return CallTool.Result(content: [.text("Git not available")], isError: true)
        }

        let maxEntries = params.arguments?["max_entries"]?.intValue ?? 20
        let since = params.arguments?["since"]?.stringValue

        do {
            let entries = try await git.log(maxEntries: maxEntries, since: since)
            if entries.isEmpty {
                return CallTool.Result(content: [.text("No changes found.")])
            }

            var lines: [String] = ["Vault changelog (\(entries.count) entries):", ""]
            for entry in entries {
                lines.append("- **\(entry.message)**")
                lines.append("  Commit: `\(entry.hash.prefix(8))` | Date: \(entry.date)")
            }

            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
        }
    }

    // MARK: - Reference Handlers (Phase 5)

    private static func handleListReferences(
        params: CallTool.Parameters,
        referenceManager: ReferenceManager
    ) -> CallTool.Result {
        let directory = params.arguments?["directory"]?.stringValue
        let refs = referenceManager.listReferences(directory: directory)

        if refs.isEmpty {
            return CallTool.Result(content: [.text("No PDF references found.")])
        }

        var lines: [String] = ["Found \(refs.count) reference(s):", ""]
        for ref in refs {
            let authorStr = ref.author.map { " by \($0)" } ?? ""
            lines.append("- **\(ref.title)**\(authorStr)")
            lines.append("  Path: `\(ref.relativePath)` | Pages: \(ref.pageCount) | Size: \(String(format: "%.1f", ref.fileSizeMB)) MB")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
    }

    private static func handleReadReference(
        params: CallTool.Parameters,
        referenceManager: ReferenceManager
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: path")], isError: true)
        }

        let page = params.arguments?["page"]?.intValue
        let bookPage = params.arguments?["book_page"]?.stringValue
        let pageRange = params.arguments?["page_range"]?.stringValue
        let query = params.arguments?["query"]?.stringValue
        let maxPages = min(params.arguments?["max_pages"]?.intValue ?? 5, 20)

        do {
            // Timeout protection: corrupt PDFs can hang PDFKit indefinitely.
            // Race the actual work against a 60-second deadline.
            let result = try await withThrowingTaskGroup(of: ReferenceManager.ReferenceContent.self) { group in
                group.addTask {
                    try referenceManager.readReference(
                        relativePath: path,
                        page: page,
                        pageRange: pageRange,
                        bookPage: bookPage,
                        query: query,
                        maxPages: maxPages
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw MCPError.internalError("Timeout: PDF took longer than 60 seconds to process. The file may be corrupt or too large.")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            if result.renderedPages.isEmpty {
                return CallTool.Result(content: [.text("No pages rendered from \(path). The page may not exist.")])
            }

            // Build mixed content: text + JPEG images per page
            // Claude uses text for accurate reading, images for diagrams/equations/figures
            var content: [Tool.Content] = []
            content.append(.text("\(result.title) (\(result.totalPages) pages total)"))

            for p in result.renderedPages {
                let labelInfo = p.bookLabel.map { " (book page: \($0))" } ?? ""
                content.append(.text("--- PDF Page \(p.pageNumber)\(labelInfo) ---"))

                // Include extracted text first (fast, accurate for Claude to process)
                if let text = p.extractedText {
                    content.append(.text(text))
                }

                // Always include the image (for diagrams, figures, equations, formatting)
                content.append(.image(data: p.jpegData.base64EncodedString(), mimeType: "image/jpeg", metadata: nil))
            }

            // Include PDF outline (bookmarks/TOC) if available — structured chapter navigation
            if let outline = result.outline {
                let indent = ["", "  ", "    "]
                let tocLines = outline.prefix(50).map { entry in
                    let prefix = indent[min(entry.level, 2)]
                    return "\(prefix)- \(entry.title) (page \(entry.pageNumber))"
                }
                let truncated = outline.count > 50 ? "\n  ... (\(outline.count - 50) more entries)" : ""
                content.append(.text("## Table of Contents (from PDF bookmarks)\n" + tocLines.joined(separator: "\n") + truncated))
            }

            // Include page label info if available and useful
            if !result.pageLabels.isEmpty {
                let labelSample = result.pageLabels.sorted { $0.key < $1.key }
                    .prefix(5)
                    .map { "PDF page \($0.key) = book page \($0.value)" }
                    .joined(separator: ", ")
                content.append(.text("Page labels: \(labelSample)\(result.pageLabels.count > 5 ? "..." : "")"))
            }

            return CallTool.Result(content: content)
        } catch {
            return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
        }
    }

    private static func handleSearchReferences(
        params: CallTool.Parameters,
        searchEngine: SearchEngine
    ) -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: query")], isError: true)
        }

        let maxResults = params.arguments?["max_results"]?.intValue ?? 10
        let maxPerDoc = params.arguments?["max_per_document"]?.intValue ?? 3

        let results = searchEngine.searchReferences(
            query: query,
            maxResults: maxResults,
            maxPerDocument: maxPerDoc
        )

        if results.isEmpty {
            return CallTool.Result(content: [.text("No references found matching '\(query)'.")])
        }

        var lines: [String] = ["Found \(results.count) result(s) for '\(query)':", ""]
        for result in results {
            let pageStr = result.pageNumber.map { " -- Page \($0)" } ?? ""
            lines.append("- **\(result.title)**\(pageStr) (score: \(String(format: "%.2f", result.score)))")
            lines.append("  Path: `\(result.path)`")
            lines.append("  \(result.snippet)")
            lines.append("")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
    }

    private static func handleGetReferenceMetadata(
        params: CallTool.Parameters,
        referenceManager: ReferenceManager
    ) -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text("Missing required parameter: path")], isError: true)
        }

        do {
            let meta = try referenceManager.getMetadata(relativePath: path)
            let formatter = ISO8601DateFormatter()

            let info: [String] = [
                "Title: \(meta.title ?? "Unknown")",
                "Author: \(meta.author ?? "Unknown")",
                "Subject: \(meta.subject ?? "N/A")",
                "Pages: \(meta.pageCount)",
                "Size: \(String(format: "%.1f", meta.fileSizeMB)) MB",
                "Created: \(meta.creationDate.map { formatter.string(from: $0) } ?? "Unknown")",
                "Page labels: \(meta.hasPageLabels ? "Yes (book page numbers available via book_page parameter)" : "No")"
            ]

            return CallTool.Result(content: [.text(info.joined(separator: "\n"))])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
        }
    }

    // MARK: - Resource Handlers (Phase 6)

    private static func handleIndexResource(
        vaultManager: VaultManager
    ) async throws -> ReadResource.Result {
        let notes = (try? await vaultManager.listNotes()) ?? []

        let entries: [[String: Any]] = notes.map { note in
            var entry: [String: Any] = [
                "path": note.relativePath,
                "title": note.title
            ]
            if !note.tags.isEmpty {
                entry["tags"] = note.tags
            }
            return entry
        }

        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://index", mimeType: "application/json")
        ])
    }

    private static func handleRecentResource(
        vaultManager: VaultManager
    ) async throws -> ReadResource.Result {
        let notes = (try? await vaultManager.listNotes()) ?? []
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        let recent = notes.filter { $0.modifiedDate >= sevenDaysAgo }

        let formatter = ISO8601DateFormatter()
        let entries: [[String: Any]] = recent.map { note in
            [
                "path": note.relativePath,
                "title": note.title,
                "modified": formatter.string(from: note.modifiedDate)
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://recent", mimeType: "application/json")
        ])
    }

    private static func handleTagsResource(
        vaultManager: VaultManager
    ) async throws -> ReadResource.Result {
        let notes = (try? await vaultManager.listNotes()) ?? []

        var tagCounts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                tagCounts[tag, default: 0] += 1
            }
        }

        let data = try JSONSerialization.data(withJSONObject: tagCounts, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "{}"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://tags", mimeType: "application/json")
        ])
    }

    private static func handleReferencesResource(
        referenceManager: ReferenceManager
    ) -> ReadResource.Result {
        let refs = referenceManager.listReferences()

        let entries: [[String: Any]] = refs.map { ref in
            var entry: [String: Any] = [
                "path": ref.relativePath,
                "title": ref.title,
                "pages": ref.pageCount,
                "sizeMB": ref.fileSizeMB
            ]
            if let author = ref.author {
                entry["author"] = author
            }
            return entry
        }

        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://references", mimeType: "application/json")
        ])
    }
}
