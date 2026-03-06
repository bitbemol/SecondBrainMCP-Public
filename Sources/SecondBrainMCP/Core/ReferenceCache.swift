import Foundation
import CryptoKit

/// Pure functions for reading/writing the per-page text cache for PDF references.
/// No instances, no mutable state — just static methods operating on the filesystem.
///
/// Cache structure per PDF:
/// ```
/// .secondbrain-mcp/cache/references/<sha256-hash>/
/// ├── path.txt          # PDF relative path (e.g. "references/book.pdf")
/// ├── metadata.json     # CacheMetadata: title, author, pages, sourceModified
/// ├── page_001.txt      # Extracted text per page
/// └── page_NNN.txt
/// ```
enum ReferenceCache {

    struct CacheMetadata: Codable, Sendable {
        let title: String?
        let author: String?
        let pages: Int
        let cachedAt: String
        let sourceModified: Date
        let totalPDFPages: Int?

        enum CodingKeys: String, CodingKey {
            case title, author, pages, cachedAt, sourceModified, totalPDFPages
        }

        init(title: String?, author: String?, pages: Int, cachedAt: String, sourceModified: Date, totalPDFPages: Int?) {
            self.title = title
            self.author = author
            self.pages = pages
            self.cachedAt = cachedAt
            self.sourceModified = sourceModified
            self.totalPDFPages = totalPDFPages
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            pages = try c.decode(Int.self, forKey: .pages)
            cachedAt = try c.decode(String.self, forKey: .cachedAt)
            sourceModified = try c.decode(Date.self, forKey: .sourceModified)
            totalPDFPages = try c.decodeIfPresent(Int.self, forKey: .totalPDFPages)
        }
    }

    /// Result of reading a cached PDF: pages + metadata in one disk pass.
    struct CachedPDFResult: Sendable {
        struct Page: Sendable {
            let pageNumber: Int
            let text: String
        }
        let pages: [Page]
        let title: String?
        let author: String?
        let pageCount: Int
        let totalPDFPages: Int?
    }

    // MARK: - Read

    /// Read all cached pages and metadata for a PDF in one disk pass.
    /// Returns nil if cache is stale, missing, or empty.
    /// Pure function: only reads filesystem, no mutable state.
    static func readCachedPDF(
        vaultPath: String,
        relativePath: String,
        sourceModified: Date
    ) -> CachedPDFResult? {
        let dir = cacheDirectory(forPDF: relativePath, vaultPath: vaultPath)
        let metadataPath = dir + "/metadata.json"

        guard FileManager.default.fileExists(atPath: metadataPath),
              let data = FileManager.default.contents(atPath: metadataPath),
              let meta = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
            return nil
        }

        // Compare at whole-second granularity: JSONEncoder serializes Date as Double
        // (timeIntervalSinceReferenceDate), which truncates APFS nanosecond precision.
        // Without this, the filesystem date is always ~100ns larger than the stored date,
        // causing every PDF to appear "modified" and triggering re-extraction on every startup.
        guard Int(sourceModified.timeIntervalSinceReferenceDate) <= Int(meta.sourceModified.timeIntervalSinceReferenceDate) else { return nil }
        guard meta.pages > 0 else { return nil }

        var pages: [CachedPDFResult.Page] = []
        pages.reserveCapacity(meta.pages)
        for pageNum in 1...meta.pages {
            let pagePath = dir + "/page_\(String(format: "%03d", pageNum)).txt"
            if let text = try? String(contentsOfFile: pagePath, encoding: .utf8) {
                pages.append(CachedPDFResult.Page(pageNumber: pageNum, text: text))
            }
        }

        guard !pages.isEmpty else { return nil }
        return CachedPDFResult(pages: pages, title: meta.title, author: meta.author, pageCount: meta.pages, totalPDFPages: meta.totalPDFPages)
    }

    /// Read just the metadata for a cached PDF (without reading page text).
    /// Returns nil if cache is stale or missing.
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

        // Compare at whole-second granularity (see readCachedPDF for explanation)
        guard Int(sourceModified.timeIntervalSinceReferenceDate) <= Int(meta.sourceModified.timeIntervalSinceReferenceDate) else { return nil }
        return meta
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
