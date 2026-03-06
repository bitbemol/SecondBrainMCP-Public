import Testing
import Foundation
@testable import SecondBrainMCP

@Suite("SearchEngine")
struct SearchEngineTests {

    /// Create a temporary vault with notes for testing.
    private func makeTestVault() throws -> (engine: SearchEngine, vaultPath: String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngineTests-\(UUID().uuidString)").path

        let notesDir = tmpDir + "/notes"
        try FileManager.default.createDirectory(atPath: notesDir, withIntermediateDirectories: true)

        try "---\ntitle: Swift Concurrency\ntags: [swift]\n---\nActors and async await patterns in Swift. Structured concurrency with task groups."
            .write(toFile: notesDir + "/swift-concurrency.md", atomically: true, encoding: .utf8)

        try "---\ntitle: Design Patterns\ntags: [swift]\n---\nStrategy pattern, observer pattern, and dependency injection in Swift applications."
            .write(toFile: notesDir + "/design-patterns.md", atomically: true, encoding: .utf8)

        try "---\ntitle: MCP Server Notes\n---\nBuilding a Model Context Protocol server in Swift using StdioTransport."
            .write(toFile: notesDir + "/mcp-server.md", atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(atPath: notesDir + "/journal", withIntermediateDirectories: true)
        try "---\ntitle: Daily Journal\n---\nToday I worked on the search engine for the MCP server project."
            .write(toFile: notesDir + "/journal/2026-03-01.md", atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(atPath: notesDir + "/cooking", withIntermediateDirectories: true)
        try "---\ntitle: Pasta Recipe\n---\nBoil water, add salt, cook pasta for 8 minutes. Serve with tomato sauce."
            .write(toFile: notesDir + "/cooking/pasta.md", atomically: true, encoding: .utf8)

        return (SearchEngine(vaultPath: tmpDir), tmpDir)
    }

    /// Create a cached reference in a temp vault. Writes path.txt, metadata.json, and page files.
    private func createCachedReference(
        vaultPath: String,
        pdfRelativePath: String,
        title: String?,
        author: String?,
        pages: [(Int, String)]
    ) throws {
        // Create the references directory with a placeholder PDF
        let fullPDFPath = vaultPath + "/" + pdfRelativePath
        let pdfDir = (fullPDFPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: pdfDir, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: fullPDFPath))

        // Create cache directory
        let hash = ReferenceCache.hashPath(pdfRelativePath)
        let cacheDir = vaultPath + "/.secondbrain-mcp/cache/references/" + hash
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        // Write path.txt (required for SearchEngine hash → path resolution)
        try pdfRelativePath.write(toFile: cacheDir + "/path.txt", atomically: true, encoding: .utf8)

        // Write page files
        for (pageNum, text) in pages {
            try text.write(
                toFile: cacheDir + "/page_\(String(format: "%03d", pageNum)).txt",
                atomically: true, encoding: .utf8
            )
        }

        // Write metadata.json
        let meta = ReferenceCache.CacheMetadata(
            title: title, author: author, pages: pages.count,
            cachedAt: "2026-01-01", sourceModified: Date(), totalPDFPages: pages.count
        )
        try JSONEncoder().encode(meta).write(to: URL(fileURLWithPath: cacheDir + "/metadata.json"))
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Note Search Tests

    @Test("Search finds matching notes")
    func basicSearch() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "swift")
        #expect(results.count >= 2)
        let paths = results.map(\.path)
        #expect(paths.contains("notes/swift-concurrency.md"))
        #expect(paths.contains("notes/design-patterns.md"))
    }

    @Test("Title matches score higher than body matches")
    func titleBoost() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "concurrency")
        #expect(!results.isEmpty)
        #expect(results[0].path == "notes/swift-concurrency.md")
    }

    @Test("Search returns snippets with context")
    func snippets() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "pasta")
        #expect(!results.isEmpty)
        #expect(results[0].snippet.lowercased().contains("pasta"))
    }

    @Test("Empty query returns no results")
    func emptyQuery() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "")
        #expect(results.isEmpty)
    }

    @Test("Query with no matches returns empty")
    func noMatches() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "quantum entanglement")
        #expect(results.isEmpty)
    }

    @Test("max_results limits output")
    func maxResults() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "swift", maxResults: 1)
        #expect(results.count == 1)
    }

    @Test("All results are notes")
    func sourceFilter() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "swift")
        #expect(results.allSatisfy { $0.source == .note })
    }

    @Test("Multi-word query matches documents with both terms")
    func multiWordQuery() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "MCP server")
        #expect(!results.isEmpty)
        #expect(results[0].path == "notes/mcp-server.md")
    }

    @Test("Search is case insensitive")
    func caseInsensitive() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let lower = engine.searchNotes(query: "swift")
        let upper = engine.searchNotes(query: "SWIFT")
        #expect(lower.count == upper.count)
    }

    @Test("Search finds notes in subdirectories")
    func subdirectorySearch() throws {
        let (engine, path) = try makeTestVault()
        defer { cleanup(path) }

        let results = engine.searchNotes(query: "pasta")
        #expect(!results.isEmpty)
        #expect(results[0].path == "notes/cooking/pasta.md")
    }

    // MARK: - Reference Search Tests

    @Test("Reference search finds cached pages")
    func referenceSearch() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngineRefTests-\(UUID().uuidString)").path
        defer { cleanup(tmpDir) }

        try createCachedReference(
            vaultPath: tmpDir,
            pdfRelativePath: "references/test-book.pdf",
            title: "ML Book",
            author: "Author",
            pages: [
                (1, "Introduction to machine learning algorithms and neural networks."),
                (2, "Deep learning uses backpropagation to train neural networks with multiple layers."),
                (3, "Random forests and gradient boosting are ensemble methods for classification.")
            ]
        )

        let engine = SearchEngine(vaultPath: tmpDir)
        let results = engine.searchReferences(query: "neural networks")

        #expect(!results.isEmpty)
        #expect(results[0].source == .reference)
        #expect(results[0].path == "references/test-book.pdf")
        #expect(results[0].title == "ML Book")
    }

    @Test("Reference search respects maxPerDocument")
    func referenceMaxPerDocument() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEnginePerDocTests-\(UUID().uuidString)").path
        defer { cleanup(tmpDir) }

        try createCachedReference(
            vaultPath: tmpDir,
            pdfRelativePath: "references/book.pdf",
            title: "Algo Book",
            author: nil,
            pages: (1...5).map { ($0, "Chapter \($0) covers algorithms and data structures in detail.") }
        )

        let engine = SearchEngine(vaultPath: tmpDir)
        let results = engine.searchReferences(query: "algorithms", maxPerDocument: 2)
        #expect(results.count == 2)
    }

    @Test("Reference search skips placeholder pages")
    func referenceSkipsPlaceholders() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEnginePlaceholderTests-\(UUID().uuidString)").path
        defer { cleanup(tmpDir) }

        try createCachedReference(
            vaultPath: tmpDir,
            pdfRelativePath: "references/book.pdf",
            title: "Book",
            author: nil,
            pages: [
                (1, "Real content about algorithms here."),
            ]
        )

        // Add a placeholder page manually
        let hash = ReferenceCache.hashPath("references/book.pdf")
        let cacheDir = tmpDir + "/.secondbrain-mcp/cache/references/" + hash
        try "[SecondBrainMCP: page 2 extraction failed — subprocess timed out or crashed. Manual review recommended.]"
            .write(toFile: cacheDir + "/page_002.txt", atomically: true, encoding: .utf8)

        let engine = SearchEngine(vaultPath: tmpDir)
        let results = engine.searchReferences(query: "algorithms")
        #expect(results.count == 1)
        #expect(results[0].pageNumber == 1)
    }

    @Test("Reference search uses title from metadata.json")
    func referenceUsesMetadataTitle() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngineTitleTests-\(UUID().uuidString)").path
        defer { cleanup(tmpDir) }

        try createCachedReference(
            vaultPath: tmpDir,
            pdfRelativePath: "references/some-file-name.pdf",
            title: "Proper Book Title From Metadata",
            author: "John Doe",
            pages: [(1, "Content about unique foobar topic.")]
        )

        let engine = SearchEngine(vaultPath: tmpDir)
        let results = engine.searchReferences(query: "foobar")
        #expect(!results.isEmpty)
        #expect(results[0].title == "Proper Book Title From Metadata")
    }

    @Test("Search with no cache directory returns empty")
    func noCacheDir() {
        let engine = SearchEngine(vaultPath: "/nonexistent/path")
        let results = engine.searchReferences(query: "test")
        #expect(results.isEmpty)
    }

    @Test("Search with no notes directory returns empty")
    func noNotesDir() {
        let engine = SearchEngine(vaultPath: "/nonexistent/path")
        let results = engine.searchNotes(query: "test")
        #expect(results.isEmpty)
    }
}
