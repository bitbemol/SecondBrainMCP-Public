import Foundation

/// Short-lived subprocess entry point for page-chunked PDF extraction.
/// Single responsibility: PDFKit extraction ONLY. No disk I/O, no cache writes.
/// Returns extracted page data to the parent via stdout pipe (JSON lines).
/// The parent orchestrator owns all disk operations and process lifecycle.
struct BatchExtractor {

    /// A single extracted page. Codable for JSON-line serialization over the stdout pipe.
    /// Short keys minimize pipe bandwidth for large page counts.
    struct PageOutput: Codable, Sendable {
        let p: Int    // page number (1-indexed)
        let t: String // extracted text
    }

    /// Extract pages [startPage, endPage] from a single PDF. Returns page data.
    /// Pure PDFKit work — no disk I/O, no cache writes, no side effects.
    /// The parent orchestrator handles cache writing after receiving this data.
    static func extract(config: ServerConfig.ExtractBatchConfig) -> [PageOutput] {
        let fullPath = config.vaultPath + "/" + config.pdfRelativePath
        let url = URL(fileURLWithPath: fullPath)

        fputs("BatchExtractor: extracting pages \(config.startPage)-\(config.endPage) from \(config.pdfRelativePath)\n", stderr)

        let bundle = PDFTextExtractor.extractWithMetadata(
            at: url,
            startPage: config.startPage,
            endPage: config.endPage
        )

        fputs("BatchExtractor: extracted \(bundle.pages.count) pages\n", stderr)
        return bundle.pages.map { PageOutput(p: $0.pageNumber, t: $0.text) }
    }
}
