import Foundation

/// Read-only manager for PDF references. This actor has ZERO write methods —
/// the read-only constraint is structural, not a runtime check.
///
/// ## Design (disk-is-truth)
/// - `listReferences()` reads metadata from disk cache first, PDFKit fallback for uncached PDFs.
/// - `ensureCacheExists()` extracts uncached PDFs to disk cache for grep-based search.
/// - No in-memory caching — all state lives on disk.
actor ReferenceManager {

    private let referencesDir: String
    private let vaultPath: String

    struct ReferenceInfo: Sendable {
        let relativePath: String
        let title: String
        let author: String?
        let pageCount: Int
        let fileSizeMB: Double
    }

    struct ReferenceContent: Sendable {
        let relativePath: String
        let title: String
        let totalPages: Int
        let pages: [PDFTextExtractor.PageText]
    }

    struct ReferenceMetadata: Sendable {
        let relativePath: String
        let title: String?
        let author: String?
        let subject: String?
        let pageCount: Int
        let fileSizeMB: Double
        let creationDate: Date?
        let textExtractable: Bool
    }

    init(vaultPath: String) {
        self.vaultPath = vaultPath
        self.referencesDir = vaultPath + "/references"
    }

    // MARK: - Read Operations (the ONLY operations)

    /// List all PDF files in the reference library.
    /// Reads metadata from disk cache (metadata.json) when available.
    /// Falls back to PDFKit `lightMetadata()` for uncached PDFs.
    func listReferences(directory: String? = nil) -> [ReferenceInfo] {
        let baseDir: String
        if let directory {
            baseDir = referencesDir + "/" + directory
        } else {
            baseDir = referencesDir
        }

        guard FileManager.default.fileExists(atPath: baseDir) else { return [] }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }

        var results: [ReferenceInfo] = []
        while let relativePart = enumerator.nextObject() as? String {
            guard (relativePart as NSString).pathExtension.lowercased() == "pdf" else { continue }

            let fullPath = baseDir + "/" + relativePart
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            let vaultRelative: String
            if let directory {
                vaultRelative = "references/" + directory + "/" + relativePart
            } else {
                vaultRelative = "references/" + relativePart
            }

            let title: String
            let author: String?
            let pageCount: Int
            let fileSizeMB: Double

            // Read file attributes once
            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            if let size = attrs?[.size] as? UInt64 {
                fileSizeMB = Double(size) / (1024 * 1024)
            } else {
                fileSizeMB = 0
            }

            // Try disk cache first (metadata.json), then PDFKit fallback
            if let sourceModified = attrs?[.modificationDate] as? Date,
               let cacheMeta = ReferenceCache.readMetadata(
                   vaultPath: vaultPath, relativePath: vaultRelative, sourceModified: sourceModified
               ) {
                title = cacheMeta.title ?? MarkdownParser.titleFromFilename((relativePart as NSString).lastPathComponent)
                author = cacheMeta.author
                pageCount = cacheMeta.totalPDFPages ?? cacheMeta.pages
            } else if let meta = PDFTextExtractor.lightMetadata(at: URL(fileURLWithPath: fullPath)) {
                title = meta.title ?? MarkdownParser.titleFromFilename((relativePart as NSString).lastPathComponent)
                author = meta.author
                pageCount = meta.pageCount
            } else {
                title = MarkdownParser.titleFromFilename((relativePart as NSString).lastPathComponent)
                author = nil
                pageCount = 0
            }

            results.append(ReferenceInfo(
                relativePath: vaultRelative,
                title: title,
                author: author,
                pageCount: pageCount,
                fileSizeMB: fileSizeMB
            ))
        }

        return results.sorted { $0.relativePath < $1.relativePath }
    }

    /// Read pages from a PDF. Supports specific page, page range, query, or first N pages.
    func readReference(
        relativePath: String,
        page: Int? = nil,
        pageRange: String? = nil,
        query: String? = nil,
        maxPages: Int = 10
    ) throws -> ReferenceContent {
        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: ["pdf"]
        )

        let url = URL(fileURLWithPath: resolved)
        guard let meta = PDFTextExtractor.metadata(at: url) else {
            throw ReferenceError.cannotOpenPDF(relativePath)
        }

        let title = meta.title ?? MarkdownParser.titleFromFilename((resolved as NSString).lastPathComponent)
        let pages: [PDFTextExtractor.PageText]

        if let query {
            pages = PDFTextExtractor.search(at: url, query: query, maxResults: maxPages)
        } else if let page {
            if let p = PDFTextExtractor.extractPage(at: url, page: page) {
                pages = [p]
            } else {
                pages = []
            }
        } else if let pageRange {
            let bounds = parsePageRange(pageRange, totalPages: meta.pageCount)
            pages = PDFTextExtractor.extractPages(at: url, pages: bounds)
        } else {
            pages = PDFTextExtractor.extractAll(at: url, maxPages: maxPages)
        }

        return ReferenceContent(
            relativePath: relativePath,
            title: title,
            totalPages: meta.pageCount,
            pages: pages
        )
    }

    /// Get metadata about a specific PDF (full metadata including text-extractability check).
    func getMetadata(relativePath: String) throws -> ReferenceMetadata {
        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: ["pdf"]
        )

        let url = URL(fileURLWithPath: resolved)
        guard let meta = PDFTextExtractor.metadata(at: url) else {
            throw ReferenceError.cannotOpenPDF(relativePath)
        }

        return ReferenceMetadata(
            relativePath: relativePath,
            title: meta.title,
            author: meta.author,
            subject: meta.subject,
            pageCount: meta.pageCount,
            fileSizeMB: meta.fileSizeMB,
            creationDate: meta.creationDate,
            textExtractable: meta.textExtractable
        )
    }

    // MARK: - Cache Management

    /// Ensure all PDFs have cache files on disk. Extracts only uncached PDFs.
    /// Writes `path.txt` in each cache directory so SearchEngine can resolve
    /// cache hashes back to PDF paths without scanning the references/ directory.
    /// Does NOT load page content into memory — pure disk I/O.
    func ensureCacheExists(
        maxPagesPerPDF: Int = 15_000,
        concurrency: Int = 4
    ) async {
        let pdfPaths = listPDFPaths()

        ReferenceCache.ensureCacheRootExists(vaultPath: vaultPath)

        var uncachedPDFs: [(relativePath: String, filenameTitle: String, sourceModified: Date)] = []

        for pdfPath in pdfPaths {
            let fullPath = vaultPath + "/" + pdfPath.relativePath
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let sourceModified = attrs[.modificationDate] as? Date else { continue }

            // Always write path.txt so SearchEngine can resolve hash → PDF path
            let cacheDir = ReferenceCache.cacheDirectory(forPDF: pdfPath.relativePath, vaultPath: vaultPath)
            let pathFile = cacheDir + "/path.txt"
            if !FileManager.default.fileExists(atPath: pathFile) {
                try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
                try? pdfPath.relativePath.write(toFile: pathFile, atomically: true, encoding: .utf8)
            }

            // Only read metadata.json (1 file) instead of readCachedPDF (all page files).
            // We just need page counts to check if cache is complete.
            let meta = ReferenceCache.readMetadata(
                vaultPath: vaultPath, relativePath: pdfPath.relativePath, sourceModified: sourceModified
            )
            if let meta {
                let isPartial: Bool
                if let totalPages = meta.totalPDFPages {
                    isPartial = meta.pages < totalPages && meta.pages < maxPagesPerPDF
                } else {
                    isPartial = true
                }
                if !isPartial { continue }
            }

            if let meta {
                fputs("SecondBrainMCP: re-extract (partial: \(meta.pages)/\(meta.totalPDFPages ?? -1)): \(pdfPath.relativePath)\n", stderr)
            } else {
                fputs("SecondBrainMCP: re-extract (no cache): \(pdfPath.relativePath)\n", stderr)
            }
            uncachedPDFs.append((
                relativePath: pdfPath.relativePath,
                filenameTitle: pdfPath.filenameTitle,
                sourceModified: sourceModified
            ))
        }

        guard !uncachedPDFs.isEmpty else {
            fputs("SecondBrainMCP: all \(pdfPaths.count) PDFs cached, nothing to extract\n", stderr)
            return
        }

        // Acquire extraction lock — only one server instance extracts at a time
        let lockDir = vaultPath + "/.secondbrain-mcp"
        try? FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
        let lockPath = lockDir + "/extraction.lock"
        let lockFd = open(lockPath, O_CREAT | O_WRONLY, 0o644)

        if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            if lockFd >= 0 { close(lockFd) }
            fputs("SecondBrainMCP: another instance is extracting, skipping\n", stderr)
            return
        }

        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        fputs("SecondBrainMCP: \(uncachedPDFs.count) PDFs need cache extraction\n", stderr)

        struct ChunkWork: Sendable {
            let pdfRelativePath: String
            let startPage: Int
            let endPage: Int
        }

        struct PDFInfo {
            let pageCount: Int
            let sourceModified: Date
            let filenameTitle: String
            let title: String?
            let author: String?
        }

        let pagesPerChunk = 50
        var allChunks: [ChunkWork] = []
        var pdfInfoMap: [String: PDFInfo] = [:]

        for pdf in uncachedPDFs {
            let fullPath = vaultPath + "/" + pdf.relativePath
            let url = URL(fileURLWithPath: fullPath)

            let meta: PDFTextExtractor.PDFMetadata? = autoreleasepool {
                PDFTextExtractor.lightMetadata(at: url)
            }
            guard let meta, meta.pageCount > 0 else { continue }

            let pagesToExtract = min(meta.pageCount, maxPagesPerPDF)

            let cacheDir = ReferenceCache.cacheDirectory(forPDF: pdf.relativePath, vaultPath: vaultPath)
            // Preserve path.txt when clearing cache
            let existingPathTxt = try? String(contentsOfFile: cacheDir + "/path.txt", encoding: .utf8)
            try? FileManager.default.removeItem(atPath: cacheDir)
            try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            try? (existingPathTxt ?? pdf.relativePath).write(
                toFile: cacheDir + "/path.txt", atomically: true, encoding: .utf8
            )

            var start = 1
            while start <= pagesToExtract {
                let end = min(start + pagesPerChunk - 1, pagesToExtract)
                allChunks.append(ChunkWork(pdfRelativePath: pdf.relativePath, startPage: start, endPage: end))
                start = end + 1
            }

            pdfInfoMap[pdf.relativePath] = PDFInfo(
                pageCount: meta.pageCount, sourceModified: pdf.sourceModified,
                filenameTitle: pdf.filenameTitle, title: meta.title, author: meta.author
            )
        }

        let spawnConcurrency = max(2, concurrency)
        fputs("SecondBrainMCP: extraction plan: \(pdfInfoMap.count) PDFs, \(allChunks.count) chunks, concurrency \(spawnConcurrency)\n", stderr)

        struct ChunkResult: Sendable {
            let pdfRelativePath: String
            let startPage: Int
            let endPage: Int
            let extraction: SubprocessSpawner.ExtractionResult
        }

        var completedChunks = 0
        let totalChunks = allChunks.count
        let vp = self.vaultPath

        await withTaskGroup(of: ChunkResult.self) { group in
            var nextIndex = 0

            while nextIndex < allChunks.count, nextIndex < spawnConcurrency {
                let chunk = allChunks[nextIndex]
                group.addTask {
                    let extraction = (try? await SubprocessSpawner.extractPages(
                        vaultPath: vp, pdfRelativePath: chunk.pdfRelativePath,
                        startPage: chunk.startPage, endPage: chunk.endPage
                    )) ?? SubprocessSpawner.ExtractionResult(pages: [], completed: false)
                    return ChunkResult(
                        pdfRelativePath: chunk.pdfRelativePath, startPage: chunk.startPage,
                        endPage: chunk.endPage, extraction: extraction
                    )
                }
                nextIndex += 1
            }

            for await result in group {
                let cacheDir = ReferenceCache.cacheDirectory(
                    forPDF: result.pdfRelativePath, vaultPath: vp
                )

                let extractedPageNumbers = Set(result.extraction.pages.map { $0.p })
                for page in result.extraction.pages {
                    let pagePath = cacheDir + "/page_\(String(format: "%03d", page.p)).txt"
                    try? page.t.write(toFile: pagePath, atomically: true, encoding: .utf8)
                }

                if !result.extraction.completed {
                    for pageNum in result.startPage...result.endPage {
                        guard !extractedPageNumbers.contains(pageNum) else { continue }
                        let pagePath = cacheDir + "/page_\(String(format: "%03d", pageNum)).txt"
                        let warning = PagePlaceholder.extractionFailed(page: pageNum).message
                        try? warning.write(toFile: pagePath, atomically: true, encoding: .utf8)
                    }
                    fputs("SecondBrainMCP: chunk failed (pages \(result.startPage)-\(result.endPage) of \(result.pdfRelativePath)), salvaged \(extractedPageNumbers.count)/\(result.endPage - result.startPage + 1) pages\n", stderr)
                }

                completedChunks += 1
                if completedChunks % 20 == 0 || completedChunks == totalChunks {
                    fputs("SecondBrainMCP: \(completedChunks)/\(totalChunks) chunks done\n", stderr)
                }

                if nextIndex < allChunks.count {
                    let chunk = allChunks[nextIndex]
                    group.addTask {
                        let extraction = (try? await SubprocessSpawner.extractPages(
                            vaultPath: vp, pdfRelativePath: chunk.pdfRelativePath,
                            startPage: chunk.startPage, endPage: chunk.endPage
                        )) ?? SubprocessSpawner.ExtractionResult(pages: [], completed: false)
                        return ChunkResult(
                            pdfRelativePath: chunk.pdfRelativePath, startPage: chunk.startPage,
                            endPage: chunk.endPage, extraction: extraction
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        // Write metadata.json for each extracted PDF
        for (pdfPath, info) in pdfInfoMap {
            let cacheDir = ReferenceCache.cacheDirectory(forPDF: pdfPath, vaultPath: vp)
            let pageFiles = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir))?
                .filter { $0.hasPrefix("page_") && $0.hasSuffix(".txt") } ?? []
            guard !pageFiles.isEmpty else { continue }

            let cacheMeta = ReferenceCache.CacheMetadata(
                title: info.title, author: info.author, pages: pageFiles.count,
                cachedAt: ISO8601DateFormatter().string(from: Date()),
                sourceModified: info.sourceModified, totalPDFPages: info.pageCount
            )
            let metaData = try? JSONEncoder().encode(cacheMeta)
            try? metaData?.write(to: URL(fileURLWithPath: cacheDir + "/metadata.json"))
        }

        fputs("SecondBrainMCP: cache extraction complete for \(pdfInfoMap.count) PDFs\n", stderr)
    }

    // MARK: - Errors

    enum ReferenceError: Error, CustomStringConvertible {
        case cannotOpenPDF(String)

        var description: String {
            switch self {
            case .cannotOpenPDF(let path):
                return "Cannot open PDF: \(path)"
            }
        }
    }

    // MARK: - Private

    private struct PDFPath: Sendable {
        let relativePath: String
        let filenameTitle: String
    }

    private func listPDFPaths() -> [PDFPath] {
        guard FileManager.default.fileExists(atPath: referencesDir) else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: referencesDir) else { return [] }

        var results: [PDFPath] = []
        while let relativePart = enumerator.nextObject() as? String {
            guard (relativePart as NSString).pathExtension.lowercased() == "pdf" else { continue }
            let fullPath = referencesDir + "/" + relativePart
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            results.append(PDFPath(
                relativePath: "references/" + relativePart,
                filenameTitle: MarkdownParser.titleFromFilename((relativePart as NSString).lastPathComponent)
            ))
        }

        return results
    }

    private func parsePageRange(_ range: String, totalPages: Int) -> Range<Int> {
        let parts = range.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else {
            return 1..<(min(totalPages, 10) + 1)
        }
        let start = max(1, parts[0])
        let end = min(totalPages, parts[1])
        return start..<(end + 1)
    }
}
