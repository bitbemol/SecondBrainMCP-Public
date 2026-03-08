import Foundation
import PDFKit
import AppKit

/// Renders PDF pages to JPEG images using PDFKit.
/// Struct with static methods — stateless, no concurrency concerns.
///
/// Uses `PDFPage.thumbnail(of:for:)` for rendering, which handles page rotation,
/// cropping, and scaling automatically. Each page is rendered inside its own
/// `autoreleasepool` to limit memory to one page at a time.
///
/// CoreGraphics rendering leaks far less memory than text extraction (~5-10 MB
/// per page vs ~100-200 MB per PDF for text). Combined with per-page autoreleasepool,
/// memory stays bounded even across many calls.
struct PDFPageRenderer {

    struct RenderedPage: Sendable {
        let pageNumber: Int       // 1-indexed (user-facing)
        let bookLabel: String?    // PDFPage.label if available (e.g., "xii", "42")
        let jpegData: Data        // JPEG image bytes
        let extractedText: String? // Text content if extractable (nil for scanned/image-only pages)
    }

    struct RenderConfig: Sendable {
        /// Target DPI for rendering. PDF points are 72 per inch.
        /// 150 DPI gives crisp, readable text without excessive file size.
        let dpi: CGFloat

        /// JPEG compression quality (0.0 = maximum compression, 1.0 = no compression).
        /// 0.6 gives good text readability at ~50-150 KB per page.
        let jpegQuality: CGFloat

        /// Maximum pixel dimension (width or height). Prevents oversized images
        /// from unusually large pages (e.g., A0 posters).
        let maxDimension: CGFloat

        static let `default` = RenderConfig(dpi: 150, jpegQuality: 0.6, maxDimension: 2000)
    }

    /// Render a single PDF page to JPEG.
    /// Returns nil if the page doesn't exist or rendering fails.
    static func renderPage(
        at url: URL,
        page: Int,
        config: RenderConfig = .default
    ) -> RenderedPage? {
        let results = renderPages(at: url, pages: page..<(page + 1), config: config)
        return results.first
    }

    /// Render a contiguous range of PDF pages to JPEG images.
    /// Opens the PDF once and renders each page in its own autoreleasepool.
    /// Page numbers are 1-indexed (user-facing).
    static func renderPages(
        at url: URL,
        pages: Range<Int>,
        config: RenderConfig = .default
    ) -> [RenderedPage] {
        guard let document = PDFDocument(url: url) else { return [] }
        return renderPagesFromDocument(document, pageNumbers: Array(pages), config: config)
    }

    /// Render non-contiguous page numbers from an already-opened PDF document.
    /// Also extracts text per page (for Claude to read accurately alongside the image).
    /// This avoids opening the PDF multiple times when page numbers aren't contiguous
    /// (e.g., search results returning pages [3, 17, 42]).
    static func renderPagesFromDocument(
        _ document: PDFDocument,
        pageNumbers: [Int],
        config: RenderConfig = .default
    ) -> [RenderedPage] {
        var results: [RenderedPage] = []
        for pageNum in pageNumbers {
            let pageIndex = pageNum - 1  // PDFKit is 0-indexed
            guard pageIndex >= 0, pageIndex < document.pageCount else { continue }

            let rendered: RenderedPage? = autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return nil }

                let label = page.label
                guard let jpegData = renderPageToJPEG(page: page, config: config) else { return nil }

                // Extract text alongside the image. Detach the string to break the
                // NSString -> PDFPage -> PDFDocument reference chain.
                var text: String? = nil
                if let rawText = page.string, !rawText.isEmpty {
                    var detached = rawText
                    detached.makeContiguousUTF8()
                    text = detached
                }

                return RenderedPage(
                    pageNumber: pageNum,
                    bookLabel: label,
                    jpegData: jpegData,
                    extractedText: text
                )
            }

            if let rendered {
                results.append(rendered)
            }
        }
        return results
    }

    /// Render the first N pages (for TOC browsing).
    static func renderFirstPages(
        at url: URL,
        count: Int = 5,
        config: RenderConfig = .default
    ) -> [RenderedPage] {
        guard let document = PDFDocument(url: url) else { return [] }
        let endPage = min(document.pageCount, count)
        guard endPage > 0 else { return [] }
        return renderPagesFromDocument(document, pageNumbers: Array(1...endPage), config: config)
    }

    /// Extract page labels for all pages in a PDF.
    /// Returns a mapping from 1-indexed page number to label string.
    /// Returns nil if labels are trivial (just "1","2","3" matching page numbers).
    static func extractPageLabels(at url: URL) -> [Int: String]? {
        guard let document = PDFDocument(url: url) else { return nil }
        return extractPageLabelsFromDocument(document)
    }

    /// Extract page labels from an already-opened PDF document.
    static func extractPageLabelsFromDocument(_ document: PDFDocument) -> [Int: String]? {
        guard document.pageCount > 0 else { return nil }

        var labels: [Int: String] = [:]
        var allTrivial = true

        for i in 0..<document.pageCount {
            // autoreleasepool per page to prevent ObjC object accumulation
            // on large PDFs (1000+ pages)
            autoreleasepool {
                guard let page = document.page(at: i) else { return }
                if let label = page.label {
                    let pageNum = i + 1  // 1-indexed
                    labels[pageNum] = label
                    if label != "\(pageNum)" {
                        allTrivial = false
                    }
                }
            }
        }

        // If all labels are just "1","2","3" matching physical indices, they're useless
        if allTrivial { return nil }
        return labels.isEmpty ? nil : labels
    }

    /// Resolve a book page label to a 1-indexed PDF page number.
    /// For example, if the TOC says "page 30" and the book starts at PDF page 16,
    /// this returns 45 (16 + 30 - 1).
    static func resolveBookPage(label: String, labels: [Int: String]) -> Int? {
        for (pageNum, pageLabel) in labels {
            if pageLabel == label { return pageNum }
        }
        return nil
    }

    /// Get the total page count without rendering anything.
    static func pageCount(at url: URL) -> Int? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.pageCount
    }

    /// Outline entry from PDF bookmarks (chapter titles mapped to page numbers).
    struct OutlineEntry: Sendable {
        let title: String
        let pageNumber: Int   // 1-indexed
        let level: Int        // 0 = top-level chapter, 1 = section, 2 = subsection
    }

    /// Extract the PDF outline (bookmarks/table of contents) from an already-opened document.
    /// Returns nil if the PDF has no outline. Most well-made PDFs have one.
    /// This gives Claude structured chapter/section data without needing to visually parse TOC pages.
    static func extractOutlineFromDocument(_ document: PDFDocument) -> [OutlineEntry]? {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }

        var entries: [OutlineEntry] = []
        extractOutlineChildren(root, document: document, level: 0, into: &entries)
        return entries.isEmpty ? nil : entries
    }

    private static func extractOutlineChildren(
        _ parent: PDFOutline,
        document: PDFDocument,
        level: Int,
        into entries: inout [OutlineEntry]
    ) {
        for i in 0..<parent.numberOfChildren {
            guard let child = parent.child(at: i) else { continue }

            if let label = child.label,
               let destination = child.destination,
               let page = destination.page {
                let pageIndex = document.index(for: page)
                entries.append(OutlineEntry(
                    title: label,
                    pageNumber: pageIndex + 1,
                    level: level
                ))
            }

            // Recurse into children (subsections) — but limit depth to avoid excessive data
            if level < 2 {
                extractOutlineChildren(child, document: document, level: level + 1, into: &entries)
            }
        }
    }

    // MARK: - Private

    /// Render a single PDFPage to JPEG data.
    private static func renderPageToJPEG(page: PDFPage, config: RenderConfig) -> Data? {
        // Get page dimensions in PDF points (72 points per inch)
        let bounds = page.bounds(for: .mediaBox)
        let scale = config.dpi / 72.0

        var pixelWidth = bounds.width * scale
        var pixelHeight = bounds.height * scale

        // Handle page rotation (swap dimensions for 90/270 degree rotation)
        let rotation = page.rotation
        if rotation == 90 || rotation == 270 {
            swap(&pixelWidth, &pixelHeight)
        }

        // Cap to maxDimension, maintaining aspect ratio
        let maxDim = max(pixelWidth, pixelHeight)
        if maxDim > config.maxDimension {
            let capScale = config.maxDimension / maxDim
            pixelWidth *= capScale
            pixelHeight *= capScale
        }

        let size = NSSize(width: pixelWidth, height: pixelHeight)

        // Use thumbnail(of:for:) which handles rotation, cropping, and scaling
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)

        // Convert NSImage to JPEG data
        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: Float(config.jpegQuality))]
        )
    }
}
