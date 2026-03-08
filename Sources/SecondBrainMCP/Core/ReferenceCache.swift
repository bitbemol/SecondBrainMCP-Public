import Foundation
import CryptoKit

/// Pure functions for reading/writing the lightweight PDF reference cache.
/// No instances, no mutable state — just static methods operating on the filesystem.
///
/// Cache structure per PDF:
/// ```
/// .secondbrain-mcp/cache/references/<sha256-hash>/
/// ├── path.txt            # PDF relative path (e.g. "references/book.pdf")
/// ├── metadata.json       # CacheMetadata: title, author, totalPages, searchStrategy
/// ├── page_labels.json    # Page label mapping (only if non-trivial labels exist)
/// └── search_text.txt     # Concatenated text for grep search
/// ```
///
/// Short PDFs (<200 pages): `search_text.txt` contains full document text.
/// Long PDFs (200+ pages): `search_text.txt` contains first ~30 pages (TOC/intro).
enum ReferenceCache {

    /// Threshold: PDFs with fewer pages get full text cached for search.
    /// PDFs with more pages only get the first `tocPages` cached.
    /// 200 pages covers papers, small books, and most technical references fully.
    /// For larger books, 30 pages captures the complete TOC + intro for most textbooks.
    static let shortPDFThreshold = 200
    static let tocPages = 30

    // MARK: - Cache Metadata

    struct CacheMetadata: Codable, Sendable {
        let title: String?
        let author: String?
        let totalPages: Int
        let cachedAt: String
        let sourceModified: Date
        let searchStrategy: SearchStrategy
        let cacheVersion: Int?  // nil for pre-v2 caches → triggers rebuild

        /// Current cache format version. Bump when cache format changes
        /// (e.g., adding outline text, changing thresholds).
        /// Caches with older versions are treated as stale and rebuilt automatically.
        static let currentVersion = 3

        enum SearchStrategy: Codable, Sendable {
            case fullText              // all pages extracted (short PDFs)
            case tocOnly(pages: Int)   // only first N pages extracted (long PDFs)
        }
    }

    struct PageLabelEntry: Codable, Sendable {
        let index: Int      // 1-based page number
        let label: String   // PDFPage.label value (e.g. "xii", "42", "A-1")
    }

    // MARK: - Read

    /// Read cache metadata for a PDF. Returns nil if cache is stale or missing.
    static func readMetadata(
        vaultPath: String,
        relativePath: String,
        sourceModified: Date
    ) -> CacheMetadata? {
        let dir = cacheDirectory(forPDF: relativePath, vaultPath: vaultPath)
        let metadataPath = dir + "/metadata.json"

        guard let data = FileManager.default.contents(atPath: metadataPath),
              let meta = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
            return nil
        }

        // Reject old cache versions (e.g., caches built without outline text)
        guard (meta.cacheVersion ?? 0) >= CacheMetadata.currentVersion else { return nil }

        // Compare at whole-second granularity: JSONEncoder serializes Date as Double
        // (timeIntervalSinceReferenceDate), which truncates APFS nanosecond precision.
        guard Int(sourceModified.timeIntervalSinceReferenceDate) <= Int(meta.sourceModified.timeIntervalSinceReferenceDate) else { return nil }
        return meta
    }

    /// Read cached page labels for a PDF.
    /// Returns a mapping from 1-indexed page number to label string.
    /// Returns empty dict if no labels are cached.
    static func readPageLabels(vaultPath: String, relativePath: String) -> [Int: String] {
        let dir = cacheDirectory(forPDF: relativePath, vaultPath: vaultPath)
        let labelsPath = dir + "/page_labels.json"

        guard let data = FileManager.default.contents(atPath: labelsPath),
              let entries = try? JSONDecoder().decode([PageLabelEntry].self, from: data) else {
            return [:]
        }

        var result: [Int: String] = [:]
        for entry in entries {
            result[entry.index] = entry.label
        }
        return result
    }

    /// Read the cached search text for a PDF.
    static func readSearchText(vaultPath: String, relativePath: String) -> String? {
        let dir = cacheDirectory(forPDF: relativePath, vaultPath: vaultPath)
        let textPath = dir + "/search_text.txt"
        return try? String(contentsOfFile: textPath, encoding: .utf8)
    }

    // MARK: - Write

    /// Write complete cache for a single PDF.
    static func writeCache(
        vaultPath: String,
        relativePath: String,
        metadata: CacheMetadata,
        pageLabels: [Int: String]?,
        searchText: String
    ) {
        let dir = cacheDirectory(forPDF: relativePath, vaultPath: vaultPath)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // path.txt — so SearchEngine can resolve hash → PDF path
        try? relativePath.write(toFile: dir + "/path.txt", atomically: true, encoding: .utf8)

        // metadata.json
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: URL(fileURLWithPath: dir + "/metadata.json"))
        }

        // page_labels.json — only if labels are non-trivial
        if let labels = pageLabels, !labels.isEmpty {
            let entries = labels.map { PageLabelEntry(index: $0.key, label: $0.value) }
                .sorted { $0.index < $1.index }
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: URL(fileURLWithPath: dir + "/page_labels.json"))
            }
        }

        // search_text.txt
        try? searchText.write(toFile: dir + "/search_text.txt", atomically: true, encoding: .utf8)
    }

    /// Check if a cache directory uses the old per-page format (has page_001.txt files).
    static func isOldFormat(cacheDir: String) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir)) ?? []
        return contents.contains { $0.hasPrefix("page_") && $0.hasSuffix(".txt") && $0 != "page_labels.json" }
    }

    // MARK: - Paths

    /// Returns the cache directory path for a specific PDF.
    static func cacheDirectory(forPDF relativePath: String, vaultPath: String) -> String {
        let hash = hashPath(relativePath)
        return vaultPath + "/.secondbrain-mcp/cache/references/" + hash
    }

    /// SHA256 hash of a path string (first 16 bytes as hex).
    static func hashPath(_ path: String) -> String {
        let data = Data(path.utf8)
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Ensure the cache root directory exists.
    static func ensureCacheRootExists(vaultPath: String) {
        let cacheRoot = vaultPath + "/.secondbrain-mcp/cache/references"
        try? FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
    }
}
