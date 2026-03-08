import Foundation
import PDFKit

/// Stateless wrapper around PDFKit for text extraction, search, and metadata.
/// Struct with static methods — no state, no concurrency concerns.
///
/// Used for:
/// - Building search text cache (extractAll for short PDFs, first N pages for long PDFs)
/// - In-PDF search via findString (read_reference query parameter)
/// - PDF metadata (title, author, page count)
///
/// NOT used for page reading — that's handled by PDFPageRenderer (returns JPEG images).
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

    /// Extract text from a single page (1-indexed).
    static func extractPage(at url: URL, page: Int) -> PageText? {
        guard let document = PDFDocument(url: url) else { return nil }
        let pageIndex = page - 1
        guard pageIndex >= 0, pageIndex < document.pageCount,
              let pdfPage = document.page(at: pageIndex) else { return nil }
        var text = pdfPage.string ?? ""
        text.makeContiguousUTF8()  // Detach from PDFDocument reference chain
        return PageText(pageNumber: page, text: text)
    }

    /// Extract text from first N pages. Used for building search cache.
    /// Each page is extracted in its own autoreleasepool with string detaching
    /// to prevent CoreGraphics memory accumulation across many PDFs.
    static func extractAll(at url: URL, maxPages: Int = 10) -> [PageText] {
        guard let document = PDFDocument(url: url) else { return [] }
        return extractAllFromDocument(document, maxPages: maxPages)
    }

    /// Extract text from first N pages of an already-opened document.
    static func extractAllFromDocument(_ document: PDFDocument, maxPages: Int = 10) -> [PageText] {
        let endPage = min(document.pageCount, maxPages)
        guard endPage > 0 else { return [] }
        var results: [PageText] = []
        for pageNum in 1...endPage {
            let pageIndex = pageNum - 1
            let pageText: PageText? = autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return nil }
                // Detach the string: page.string returns NSString-bridged Swift String
                // that keeps PDFPage -> PDFDocument alive. makeContiguousUTF8() forces
                // a deep copy into native Swift storage, breaking the reference chain.
                var text = page.string ?? ""
                text.makeContiguousUTF8()
                return PageText(pageNumber: pageNum, text: text)
            }
            if let pageText {
                results.append(pageText)
            }
        }
        return results
    }

    /// Search within a PDF for a query string. Returns matching page numbers.
    /// Uses PDFKit's built-in findString which scans the text index without
    /// extracting full page text — much lighter than page.string extraction.
    static func search(at url: URL, query: String, maxResults: Int = 10) -> [Int] {
        guard let document = PDFDocument(url: url) else { return [] }
        return searchDocument(document, query: query, maxResults: maxResults)
    }

    /// Search an already-opened PDF document. Returns matching 1-indexed page numbers.
    static func searchDocument(_ document: PDFDocument, query: String, maxResults: Int = 10) -> [Int] {
        let selections = document.findString(query, withOptions: .caseInsensitive)
        var seenPages: Set<Int> = []
        var results: [Int] = []

        for selection in selections {
            guard results.count < maxResults else { break }
            let pages = selection.pages

            for page in pages {
                let pageIndex = document.index(for: page)
                let pageNum = pageIndex + 1  // Convert to 1-indexed

                guard !seenPages.contains(pageNum) else { continue }
                seenPages.insert(pageNum)
                results.append(pageNum)
            }
        }

        return results
    }

    /// Lightweight metadata: opens PDF, reads header attributes + page count.
    /// No text extraction — fast (~10-30ms per file).
    static func lightMetadata(at url: URL) -> PDFMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }

        let attrs = document.documentAttributes
        let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String
        let subject = attrs?[PDFDocumentAttribute.subjectAttribute] as? String
        let creationDate = attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date

        let fileSize: Double
        if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = fileAttrs[.size] as? UInt64 {
            fileSize = Double(size) / (1024 * 1024)
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
            textExtractable: true  // Image-based rendering works for all PDFs
        )
    }
}
