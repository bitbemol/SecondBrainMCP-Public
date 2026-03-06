import Foundation
import PDFKit

/// Stateless wrapper around PDFKit for text extraction, search, and metadata.
/// Struct with static methods — no state, no concurrency concerns.
struct PDFTextExtractor {

    struct PDFMetadata: Sendable {
        let title: String?
        let author: String?
        let subject: String?
        let pageCount: Int
        let fileSizeMB: Double
        let creationDate: Date?
        let textExtractable: Bool
    }

    struct PageText: Sendable {
        let pageNumber: Int    // 1-indexed (user-facing)
        let text: String
    }

    /// Extract text from specific pages of a PDF.
    /// Page numbers are 1-indexed (user-facing). Internally converts to 0-indexed for PDFKit.
    static func extractPages(at url: URL, pages: Range<Int>) -> [PageText] {
        guard let document = PDFDocument(url: url) else { return [] }

        var results: [PageText] = []
        for pageNum in pages {
            let pageIndex = pageNum - 1  // PDFKit is 0-indexed
            guard pageIndex >= 0, pageIndex < document.pageCount else { continue }
            guard let page = document.page(at: pageIndex) else { continue }
            let text = page.string ?? ""
            results.append(PageText(pageNumber: pageNum, text: text))
        }
        return results
    }

    /// Extract text from a single page (1-indexed).
    static func extractPage(at url: URL, page: Int) -> PageText? {
        let results = extractPages(at: url, pages: page..<(page + 1))
        return results.first
    }

    /// Extract all text from a PDF, up to maxPages.
    static func extractAll(at url: URL, maxPages: Int = 10) -> [PageText] {
        guard let document = PDFDocument(url: url) else { return [] }
        let endPage = min(document.pageCount, maxPages)
        var results: [PageText] = []
        for pageNum in 1...endPage {
            let pageIndex = pageNum - 1
            guard let page = document.page(at: pageIndex) else { continue }
            let text = page.string ?? ""
            results.append(PageText(pageNumber: pageNum, text: text))
        }
        return results
    }

    /// Combined extraction + metadata in a single PDF open. Avoids opening the same
    /// PDF 3 times (extractAll + extractPages + lightMetadata) which causes CoreGraphics
    /// lock contention under high concurrency.
    struct ExtractionBundle: Sendable {
        let pages: [PageText]
        let metadata: PDFMetadata?
    }

    /// Force a deep copy of a bridged NSString so it no longer references the
    /// PDFPage → PDFDocument chain. Without this, every extracted page's String
    /// keeps the entire source PDFDocument alive in memory via lazy bridging.
    /// Uses byte-level copy (String → [UInt8] → String) to guarantee no shared storage.
    private static func detach(_ s: String) -> String {
        String(decoding: Array(s.utf8), as: UTF8.self)
    }

    static func extractWithMetadata(at url: URL, startPage: Int = 1, endPage: Int = Int.max) -> ExtractionBundle {
        // PDFKit is Objective-C underneath. Without autoreleasepool, ObjC objects
        // (PDFDocument internals, page render caches, attributed strings) accumulate
        // and never get freed until the enclosing scope completes. In a TaskGroup with
        // 12 concurrent extractions, this causes multi-GB memory spikes.
        //
        // CRITICAL: All strings from PDFKit (page.string, document attributes) must be
        // deep-copied via detach() before leaving the autoreleasepool. Swift bridges
        // NSString lazily — the String holds a reference to the NSString, which holds
        // the PDFPage, which holds the PDFDocument. Without detach(), the autoreleasepool
        // cannot free the PDFDocument because the returned strings keep the entire
        // object graph alive. This caused 47+ GB memory consumption for 414 PDFs.
        autoreleasepool {
            guard let document = PDFDocument(url: url) else {
                return ExtractionBundle(pages: [], metadata: nil)
            }

            // Extract pages — detach every string to break NSString bridge
            let effectiveStart = max(1, startPage)
            let effectiveEnd = min(document.pageCount, endPage)
            var pages: [PageText] = []
            if effectiveStart <= effectiveEnd {
                for pageNum in effectiveStart...effectiveEnd {
                    let pageIndex = pageNum - 1
                    guard let page = document.page(at: pageIndex) else {
                        pages.append(PageText(pageNumber: pageNum, text: PagePlaceholder.inaccessible(page: pageNum).message))
                        continue
                    }
                    if let rawText = page.string, !rawText.isEmpty {
                        pages.append(PageText(pageNumber: pageNum, text: detach(rawText)))
                    } else {
                        pages.append(PageText(pageNumber: pageNum, text: PagePlaceholder.blank(page: pageNum).message))
                    }
                }
            }

            // Extract metadata from same document (no re-open)
            // Detach all strings — same bridging issue applies to document attributes
            let attrs = document.documentAttributes
            let title = (attrs?[PDFDocumentAttribute.titleAttribute] as? String).map(detach)
            let author = (attrs?[PDFDocumentAttribute.authorAttribute] as? String).map(detach)
            let subject = (attrs?[PDFDocumentAttribute.subjectAttribute] as? String).map(detach)
            let creationDate = attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date

            let fileSize: Double
            if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = fileAttrs[.size] as? UInt64 {
                fileSize = Double(size) / (1024 * 1024)
            } else {
                fileSize = 0
            }

            let metadata = PDFMetadata(
                title: title, author: author, subject: subject,
                pageCount: document.pageCount, fileSizeMB: fileSize,
                creationDate: creationDate, textExtractable: true
            )

            return ExtractionBundle(pages: pages, metadata: metadata)
        }
    }

    /// Search within a PDF for a query string. Returns matching pages with context.
    static func search(at url: URL, query: String, maxResults: Int = 10) -> [PageText] {
        guard let document = PDFDocument(url: url) else { return [] }

        let selections = document.findString(query, withOptions: .caseInsensitive)
        var seenPages: Set<Int> = []
        var results: [PageText] = []

        for selection in selections {
            guard results.count < maxResults else { break }
            let pages = selection.pages

            for page in pages {
                let pageIndex = document.index(for: page)
                let pageNum = pageIndex + 1  // Convert to 1-indexed

                guard !seenPages.contains(pageNum) else { continue }
                seenPages.insert(pageNum)

                let text = page.string ?? ""
                results.append(PageText(pageNumber: pageNum, text: text))
            }
        }

        return results
    }

    /// Get metadata about a PDF without extracting all text.
    static func metadata(at url: URL) -> PDFMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }

        let attrs = document.documentAttributes
        let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String
        let subject = attrs?[PDFDocumentAttribute.subjectAttribute] as? String
        let creationDate = attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date

        // Check if text is extractable by sampling first few pages
        let textExtractable = isTextExtractable(document: document)

        // File size
        let fileSize: Double
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileSize = Double(size) / (1024 * 1024) // bytes → MB
        } else {
            fileSize = 0
        }

        return PDFMetadata(
            title: title,
            author: author,
            subject: subject,
            pageCount: document.pageCount,
            fileSizeMB: fileSize,
            creationDate: creationDate,
            textExtractable: textExtractable
        )
    }

    /// Lightweight metadata that skips the text-extractability check.
    /// Opens the PDF and reads header attributes + page count without extracting any page text.
    /// ~10-30ms per file vs ~200-500ms for full metadata() with text sampling.
    /// Use this for listing large numbers of PDFs where speed matters.
    static func lightMetadata(at url: URL) -> PDFMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }

        let attrs = document.documentAttributes
        let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String
        let subject = attrs?[PDFDocumentAttribute.subjectAttribute] as? String
        let creationDate = attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date

        // File size
        let fileSize: Double
        if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = fileAttrs[.size] as? UInt64 {
            fileSize = Double(size) / (1024 * 1024)
        } else {
            fileSize = 0
        }

        // Skip isTextExtractable — that's the slow part (extracts text from 3 pages)
        return PDFMetadata(
            title: title,
            author: author,
            subject: subject,
            pageCount: document.pageCount,
            fileSizeMB: fileSize,
            creationDate: creationDate,
            textExtractable: true // optimistic default; full check done on demand
        )
    }

    /// Check if a PDF has extractable text by sampling the first 3 pages.
    private static func isTextExtractable(document: PDFDocument) -> Bool {
        let pagesToCheck = min(3, document.pageCount)
        for i in 0..<pagesToCheck {
            if let page = document.page(at: i),
               let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }
}
