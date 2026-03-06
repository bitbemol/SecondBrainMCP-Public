import Foundation

/// Disk-based search engine that greps files on demand instead of loading everything into memory.
/// No startup indexing, no in-memory index — just fast SSD reads when a search query arrives.
///
/// ## Architecture
/// - `searchNotes()`: greps `.md` files in `notes/` via `/usr/bin/grep`
/// - `searchReferences()`: greps cached `.txt` files in `.secondbrain-mcp/cache/references/`
/// - Each cache directory contains `path.txt` (PDF relative path) and `metadata.json` (title, author)
///   written by `ReferenceManager.ensureCacheExists()` — enables O(1) path and title resolution per hit
/// - Sendable struct: no mutable state, no actor needed, safe for concurrent use
struct SearchEngine: Sendable {

    enum EntrySource: Sendable {
        case note
        case reference
    }

    struct SearchResult: Sendable {
        let path: String
        let source: EntrySource
        let pageNumber: Int?
        let title: String
        let snippet: String
        let score: Double
    }

    private let vaultPath: String

    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    // MARK: - Note Search

    /// Search notes by grepping markdown files in notes/.
    func searchNotes(query: String, maxResults: Int = 20) -> [SearchResult] {
        let notesDir = vaultPath + "/notes"
        guard FileManager.default.fileExists(atPath: notesDir) else { return [] }

        let terms = tokenize(query)
        guard !terms.isEmpty else { return [] }

        let candidateFiles = grepFiles(
            directory: notesDir,
            pattern: terms[0],
            fileExtensions: ["md", "markdown"]
        )

        var results: [SearchResult] = []

        for filePath in candidateFiles {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            let contentLower = content.lowercased()

            let allMatch = terms.allSatisfy { contentLower.contains($0) }
            guard allMatch else { continue }

            let relativePath = String(filePath.dropFirst(vaultPath.count + 1))
            let filename = (filePath as NSString).lastPathComponent
            let parsed = MarkdownParser.parse(content: content, filename: filename)

            let snippet = generateSnippet(content: content, terms: terms)
            let score = computeScore(content: contentLower, title: parsed.title.lowercased(), terms: terms)

            results.append(SearchResult(
                path: relativePath,
                source: .note,
                pageNumber: nil,
                title: parsed.title,
                snippet: snippet,
                score: score
            ))
        }

        // Sort by score descending, then take top N
        return Array(results.sorted { $0.score > $1.score }.prefix(maxResults))
    }

    // MARK: - Reference Search

    /// Search references by grepping cached `.txt` files in `.secondbrain-mcp/cache/references/`.
    /// Each cache directory has `path.txt` (PDF relative path) and `metadata.json` (title/author),
    /// written by `ReferenceManager.ensureCacheExists()`.
    func searchReferences(
        query: String,
        maxResults: Int = 10,
        maxPerDocument: Int = 3
    ) -> [SearchResult] {
        let cacheDir = vaultPath + "/.secondbrain-mcp/cache/references"
        guard FileManager.default.fileExists(atPath: cacheDir) else { return [] }

        let terms = tokenize(query)
        guard !terms.isEmpty else { return [] }

        let candidateFiles = grepFiles(
            directory: cacheDir,
            pattern: terms[0],
            fileExtensions: ["txt"]
        )

        struct ScoredMatch {
            let pdfPath: String
            let pageNumber: Int
            let title: String
            let snippet: String
            let score: Double
        }

        // Cache resolved path.txt and metadata.json per hash directory
        var hashDirCache: [String: (pdfPath: String, title: String)] = [:]

        var matches: [ScoredMatch] = []

        for filePath in candidateFiles {
            let filename = (filePath as NSString).lastPathComponent
            // Only match page files, skip metadata.json, path.txt, etc.
            guard filename.hasPrefix("page_"), filename.hasSuffix(".txt") else { continue }
            let pageStr = filename.dropFirst(5).dropLast(4)
            guard let pageNum = Int(pageStr) else { continue }

            let hashDirPath = (filePath as NSString).deletingLastPathComponent
            let hashDir = (hashDirPath as NSString).lastPathComponent

            // Resolve PDF path and title from cache directory (once per hash)
            let resolved: (pdfPath: String, title: String)
            if let cached = hashDirCache[hashDir] {
                resolved = cached
            } else {
                guard let r = resolveCacheDir(hashDirPath) else { continue }
                hashDirCache[hashDir] = r
                resolved = r
            }

            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }

            // Skip placeholder files (blank pages, extraction failures, etc.)
            if PagePlaceholder.isPlaceholder(content) { continue }

            let contentLower = content.lowercased()

            let allMatch = terms.allSatisfy { contentLower.contains($0) }
            guard allMatch else { continue }

            let snippet = generateSnippet(content: content, terms: terms)
            let score = computeScore(content: contentLower, title: resolved.title.lowercased(), terms: terms)

            matches.append(ScoredMatch(
                pdfPath: resolved.pdfPath,
                pageNumber: pageNum,
                title: resolved.title,
                snippet: snippet,
                score: score
            ))
        }

        let sorted = matches.sorted { $0.score > $1.score }

        var results: [SearchResult] = []
        var countPerDoc: [String: Int] = [:]

        for match in sorted {
            guard results.count < maxResults else { break }

            let count = countPerDoc[match.pdfPath, default: 0]
            if count >= maxPerDocument { continue }
            countPerDoc[match.pdfPath] = count + 1

            results.append(SearchResult(
                path: match.pdfPath,
                source: .reference,
                pageNumber: match.pageNumber,
                title: match.title,
                snippet: match.snippet,
                score: match.score
            ))
        }

        return results
    }

    // MARK: - Private: Grep

    /// Run /usr/bin/grep to find files containing a pattern.
    private func grepFiles(
        directory: String,
        pattern: String,
        fileExtensions: [String]
    ) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")

        var args: [String] = ["-r", "-l", "-i"]
        for ext in fileExtensions {
            args.append("--include=*.\(ext)")
        }
        args.append("--")
        args.append(pattern)
        args.append(directory)

        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }

        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Private: Cache Resolution

    /// Resolve a cache directory to its PDF path and title.
    /// Reads `path.txt` for the PDF relative path and `metadata.json` for the title.
    /// Returns nil if `path.txt` is missing (cache not yet initialized by ensureCacheExists).
    private func resolveCacheDir(_ hashDirPath: String) -> (pdfPath: String, title: String)? {
        let pathFile = hashDirPath + "/path.txt"
        guard let pdfPath = try? String(contentsOfFile: pathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        // Try to read title from metadata.json
        var title = MarkdownParser.titleFromFilename((pdfPath as NSString).lastPathComponent)
        let metaFile = hashDirPath + "/metadata.json"
        if let data = FileManager.default.contents(atPath: metaFile),
           let meta = try? JSONDecoder().decode(ReferenceCache.CacheMetadata.self, from: data),
           let metaTitle = meta.title, !metaTitle.isEmpty {
            title = metaTitle
        }

        return (pdfPath: pdfPath, title: title)
    }

    // MARK: - Private: Scoring & Snippets

    /// Tokenize: lowercase, split on non-alphanumeric, skip short tokens.
    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Score: count of term occurrences + title boost.
    private func computeScore(content: String, title: String, terms: [String]) -> Double {
        var score = 0.0
        for term in terms {
            var searchRange = content.startIndex..<content.endIndex
            var count = 0
            while let range = content.range(of: term, range: searchRange) {
                count += 1
                searchRange = range.upperBound..<content.endIndex
            }
            score += Double(count)

            if title.contains(term) {
                score += 5.0
            }
        }
        return score
    }

    /// Generate a ~150 char snippet around the first match of any query term.
    private func generateSnippet(content: String, terms: [String]) -> String {
        let lower = content.lowercased()

        var bestPos: String.Index?
        for term in terms {
            if let range = lower.range(of: term) {
                bestPos = range.lowerBound
                break
            }
        }

        guard let pos = bestPos else {
            return String(content.prefix(150)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let distance = content.distance(from: content.startIndex, to: pos)
        let snippetStart = max(0, distance - 60)
        let startIdx = content.index(content.startIndex, offsetBy: snippetStart)
        let endIdx = content.index(startIdx, offsetBy: min(150, content.distance(from: startIdx, to: content.endIndex)))

        var snippet = String(content[startIdx..<endIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        if snippetStart > 0 { snippet = "..." + snippet }
        if endIdx < content.endIndex { snippet = snippet + "..." }

        return snippet
    }
}
