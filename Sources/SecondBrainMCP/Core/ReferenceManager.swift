import Foundation
import PDFKit
import Darwin

/// Read-only manager for PDF references. Sendable struct — no mutable state,
/// no actor serialization. Multiple `readReference()` calls run concurrently without blocking.
/// Cache writes go to ~/Library/Application Support/SecondBrainMCP/ (outside iCloud).
///
/// ## Design (image-based)
/// - `readReference()` renders PDF pages as JPEG images via PDFPageRenderer.
/// - `ensureCacheExists()` builds lightweight cache: metadata, page labels, search text + outline.
/// - `listReferences()` reads metadata from disk cache first, PDFKit fallback for uncached.
/// - No in-memory caching — all state lives on disk.
/// - No actor isolation — all properties are `let`, all methods are non-mutating.
struct ReferenceManager: Sendable {

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
        let renderedPages: [PDFPageRenderer.RenderedPage]
        let pageLabels: [Int: String]  // 1-indexed page → book label
        let outline: [PDFPageRenderer.OutlineEntry]?  // PDF bookmarks (chapter titles + page numbers)
    }

    struct ReferenceMetadata: Sendable {
        let relativePath: String
        let title: String?
        let author: String?
        let subject: String?
        let pageCount: Int
        let fileSizeMB: Double
        let creationDate: Date?
        let hasPageLabels: Bool
    }

    init(vaultPath: String) {
        self.vaultPath = vaultPath
        self.referencesDir = vaultPath + "/references"
    }

    // MARK: - Read Operations (the ONLY operations on references/)

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
                pageCount = cacheMeta.totalPages
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

    /// Read pages from a PDF as rendered JPEG images.
    /// Opens the PDF document ONCE and reuses it for metadata, search, labels, and rendering.
    /// Supports specific page, page range, book page label, query, or first N pages.
    func readReference(
        relativePath: String,
        page: Int? = nil,
        pageRange: String? = nil,
        bookPage: String? = nil,
        query: String? = nil,
        maxPages: Int = 5
    ) throws -> ReferenceContent {
        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: ["pdf"]
        )

        let url = URL(fileURLWithPath: resolved)

        // Open the PDF ONCE — reuse this document for all operations below.
        // This avoids opening the same PDF 3-8 times per call (metadata + labels + search + render).
        guard let document = PDFDocument(url: url) else {
            throw ReferenceError.cannotOpenPDF(relativePath)
        }

        let attrs = document.documentAttributes
        let pdfTitle = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let title = pdfTitle ?? MarkdownParser.titleFromFilename((resolved as NSString).lastPathComponent)
        let totalPages = document.pageCount

        // Load page labels from cache, or extract from this document
        let pageLabels = loadPageLabels(relativePath: relativePath, document: document)

        // Extract PDF outline (bookmarks/TOC) — gives Claude structured chapter navigation
        let outline = PDFPageRenderer.extractOutlineFromDocument(document)

        let renderedPages: [PDFPageRenderer.RenderedPage]

        if let query {
            // Search within PDF, then render matching pages
            let pageNumbers = PDFTextExtractor.searchDocument(document, query: query, maxResults: maxPages)
            renderedPages = PDFPageRenderer.renderPagesFromDocument(document, pageNumbers: pageNumbers)
        } else if let bookPage {
            // Navigate by printed page label
            let targetPage: Int?
            if let pdfPage = PDFPageRenderer.resolveBookPage(label: bookPage, labels: pageLabels) {
                targetPage = pdfPage
            } else {
                targetPage = Int(bookPage)  // Fall back to interpreting as number
            }
            if let targetPage {
                renderedPages = PDFPageRenderer.renderPagesFromDocument(document, pageNumbers: [targetPage])
            } else {
                renderedPages = []
            }
        } else if let page {
            renderedPages = PDFPageRenderer.renderPagesFromDocument(document, pageNumbers: [page])
        } else if let pageRange {
            let bounds = parsePageRange(pageRange, totalPages: totalPages)
            let cappedEnd = min(bounds.upperBound, bounds.lowerBound + maxPages)
            renderedPages = PDFPageRenderer.renderPagesFromDocument(document, pageNumbers: Array(bounds.lowerBound..<cappedEnd))
        } else {
            // Default: render first N pages
            let endPage = min(totalPages, maxPages)
            let pages = endPage > 0 ? Array(1...endPage) : []
            renderedPages = PDFPageRenderer.renderPagesFromDocument(document, pageNumbers: pages)
        }

        return ReferenceContent(
            relativePath: relativePath,
            title: title,
            totalPages: totalPages,
            renderedPages: renderedPages,
            pageLabels: pageLabels,
            outline: outline
        )
    }

    /// Get metadata about a specific PDF. Uses lightMetadata to avoid text extraction.
    func getMetadata(relativePath: String) throws -> ReferenceMetadata {
        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: ["pdf"]
        )

        let url = URL(fileURLWithPath: resolved)

        // Open PDF once for both metadata and page labels
        guard let document = PDFDocument(url: url) else {
            throw ReferenceError.cannotOpenPDF(relativePath)
        }

        let attrs = document.documentAttributes
        let hasLabels = !loadPageLabels(relativePath: relativePath, document: document).isEmpty

        // File size
        let fileSize: Double
        if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: resolved),
           let size = fileAttrs[.size] as? UInt64 {
            fileSize = Double(size) / (1024 * 1024)
        } else {
            fileSize = 0
        }

        return ReferenceMetadata(
            relativePath: relativePath,
            title: attrs?[PDFDocumentAttribute.titleAttribute] as? String,
            author: attrs?[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attrs?[PDFDocumentAttribute.subjectAttribute] as? String,
            pageCount: document.pageCount,
            fileSizeMB: fileSize,
            creationDate: attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date,
            hasPageLabels: hasLabels
        )
    }

    // MARK: - Cache Management

    /// Build lightweight cache for all uncached PDFs.
    /// For each PDF: metadata, page labels, and search text (TOC or full text).
    /// No subprocesses, no per-page text files. Memory-bounded extraction.
    func ensureCacheExists() {
        let pdfPaths = listPDFPaths()
        ReferenceCache.ensureCacheRootExists(vaultPath: vaultPath)

        var uncachedPDFs: [(relativePath: String, filenameTitle: String, sourceModified: Date)] = []

        for pdfPath in pdfPaths {
            let fullPath = vaultPath + "/" + pdfPath.relativePath
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let sourceModified = attrs[.modificationDate] as? Date else { continue }

            let cacheDir = ReferenceCache.cacheDirectory(forPDF: pdfPath.relativePath, vaultPath: vaultPath)

            // Auto-migrate old cache format (per-page .txt files)
            if ReferenceCache.isOldFormat(cacheDir: cacheDir) {
                // Keep path.txt, delete everything else
                let pathTxt = try? String(contentsOfFile: cacheDir + "/path.txt", encoding: .utf8)
                try? FileManager.default.removeItem(atPath: cacheDir)
                try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
                if let pathTxt {
                    try? pathTxt.write(toFile: cacheDir + "/path.txt", atomically: true, encoding: .utf8)
                }
                // Fall through to re-cache
            }

            // Check if cache is valid
            let meta = ReferenceCache.readMetadata(
                vaultPath: vaultPath, relativePath: pdfPath.relativePath, sourceModified: sourceModified
            )
            if meta != nil { continue }  // Cache is valid

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

        // Acquire extraction lock — only one server instance caches at a time
        DataPaths.ensureRootExists(vaultPath: vaultPath)
        let lockPath = DataPaths.extractionLock(vaultPath: vaultPath)
        let lockFd = open(lockPath, O_CREAT | O_WRONLY, 0o644)

        if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            if lockFd >= 0 { close(lockFd) }
            fputs("SecondBrainMCP: another instance is caching, skipping\n", stderr)
            return
        }

        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        let startRSS = Self.currentRSSMB()
        fputs("SecondBrainMCP: \(uncachedPDFs.count) PDFs need cache building (RSS: \(startRSS) MB)\n", stderr)

        /// Safety valve: stop caching if memory exceeds this threshold to prevent OOM.
        /// CoreGraphics may leak internal caches per PDFDocument that autoreleasepool cannot reclaim.
        let maxRSSMB = 3000  // 3 GB

        var completed = 0
        for pdf in uncachedPDFs {
            // Check memory before each PDF — bail out before OOM
            let rss = Self.currentRSSMB()
            if rss > maxRSSMB {
                fputs("SecondBrainMCP: WARNING: RSS exceeded \(maxRSSMB) MB (\(rss) MB) during cache building. " +
                      "Stopping to prevent OOM. \(completed)/\(uncachedPDFs.count) PDFs cached. " +
                      "Remaining PDFs will be cached on next restart.\n", stderr)
                break
            }

            autoreleasepool {
                cacheSinglePDF(
                    relativePath: pdf.relativePath,
                    filenameTitle: pdf.filenameTitle,
                    sourceModified: pdf.sourceModified
                )
            }
            completed += 1
            if completed % 50 == 0 || completed == uncachedPDFs.count {
                fputs("SecondBrainMCP: \(completed)/\(uncachedPDFs.count) PDFs cached (RSS: \(Self.currentRSSMB()) MB)\n", stderr)
            }
        }

        fputs("SecondBrainMCP: cache building complete — \(completed)/\(uncachedPDFs.count) PDFs cached (RSS: \(Self.currentRSSMB()) MB)\n", stderr)
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

    /// Load page labels from cache, or extract from an already-opened PDF document and cache them.
    private func loadPageLabels(relativePath: String, document: PDFDocument) -> [Int: String] {
        // Try cache first
        let cached = ReferenceCache.readPageLabels(vaultPath: vaultPath, relativePath: relativePath)
        if !cached.isEmpty { return cached }

        // Extract from the already-opened document (no second PDF open)
        guard let labels = PDFPageRenderer.extractPageLabelsFromDocument(document) else {
            return [:]
        }

        // Cache for next time (writes to ~/Library/Application Support/SecondBrainMCP/)
        let dir = ReferenceCache.cacheDirectory(forPDF: relativePath, vaultPath: vaultPath)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let entries = labels.map { ReferenceCache.PageLabelEntry(index: $0.key, label: $0.value) }
            .sorted { $0.index < $1.index }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: URL(fileURLWithPath: dir + "/page_labels.json"))
        }

        return labels
    }

    /// Build cache for a single PDF: metadata, page labels, search text.
    /// Opens the PDF once and reuses the document for all operations.
    private func cacheSinglePDF(
        relativePath: String,
        filenameTitle: String,
        sourceModified: Date
    ) {
        let fullPath = vaultPath + "/" + relativePath
        let url = URL(fileURLWithPath: fullPath)

        // Open PDF ONCE — reuse for metadata, labels, and text extraction
        guard let document = PDFDocument(url: url) else {
            fputs("SecondBrainMCP: WARNING: cannot open PDF: \(relativePath)\n", stderr)
            return
        }
        guard document.pageCount > 0 else { return }

        let attrs = document.documentAttributes
        let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String

        // Extract page labels from the already-opened document
        let pageLabels = PDFPageRenderer.extractPageLabelsFromDocument(document)

        // Determine search strategy based on page count
        let isShortPDF = document.pageCount < ReferenceCache.shortPDFThreshold
        let pagesToExtract = isShortPDF ? document.pageCount : ReferenceCache.tocPages
        let strategy: ReferenceCache.CacheMetadata.SearchStrategy = isShortPDF
            ? .fullText
            : .tocOnly(pages: pagesToExtract)

        // Extract text for search from the already-opened document (limited pages, with autoreleasepool per page)
        let pages = PDFTextExtractor.extractAllFromDocument(document, maxPages: pagesToExtract)
        var searchText = pages.map { "--- Page \($0.pageNumber) ---\n\($0.text)" }.joined(separator: "\n\n")

        // Include outline entries for chapter-level search coverage.
        // Critical for long books where only first 30 pages are indexed —
        // a search for "neural networks" will match a chapter titled "Neural Networks"
        // even if the indexed pages don't mention it.
        // Each entry gets a "--- Page N ---" marker so SearchEngine resolves
        // the correct chapter start page from grep hits.
        if let outline = PDFPageRenderer.extractOutlineFromDocument(document) {
            var outlineLines: [String] = ["--- Outline ---"]
            for entry in outline {
                outlineLines.append("--- Page \(entry.pageNumber) ---")
                outlineLines.append(entry.title)
            }
            searchText += "\n\n" + outlineLines.joined(separator: "\n")
        }

        let metadata = ReferenceCache.CacheMetadata(
            title: title,
            author: author,
            totalPages: document.pageCount,
            cachedAt: ISO8601DateFormatter().string(from: Date()),
            sourceModified: sourceModified,
            searchStrategy: strategy,
            cacheVersion: ReferenceCache.CacheMetadata.currentVersion
        )

        ReferenceCache.writeCache(
            vaultPath: vaultPath,
            relativePath: relativePath,
            metadata: metadata,
            pageLabels: pageLabels,
            searchText: searchText
        )
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

    /// Get current process RSS in megabytes via mach_task_basic_info.
    /// Used to monitor memory during cache building and bail out before OOM.
    private static func currentRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / (1024 * 1024)
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
