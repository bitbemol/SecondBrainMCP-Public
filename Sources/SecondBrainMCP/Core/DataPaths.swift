import Foundation
import CryptoKit

/// Centralized path resolution for all SecondBrainMCP internal data.
///
/// All MCP server data (cache, logs, locks) lives OUTSIDE the vault in
/// `~/Library/Application Support/SecondBrainMCP/<vault-hash>/`.
/// This prevents iCloud Drive from syncing internal files, which caused
/// corrupted duplicate directories (" 2", " 3" suffixes) and grep hangs.
///
/// Only user content (notes/, references/) lives inside the vault.
enum DataPaths {

    /// Root directory for all SecondBrainMCP internal data for a given vault.
    /// `~/Library/Application Support/SecondBrainMCP/<vault-hash>/`
    static func root(vaultPath: String) -> String {
        let vaultHash = hashPath(vaultPath)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/SecondBrainMCP/" + vaultHash
    }

    /// Cache root for reference PDF text extraction.
    /// `~/Library/Application Support/SecondBrainMCP/<vault-hash>/cache/references/`
    static func cacheRoot(vaultPath: String) -> String {
        root(vaultPath: vaultPath) + "/cache/references"
    }

    /// Cache directory for a specific PDF.
    /// `~/Library/Application Support/SecondBrainMCP/<vault-hash>/cache/references/<pdf-hash>/`
    static func cacheDirectory(forPDF relativePath: String, vaultPath: String) -> String {
        let hash = hashPath(relativePath)
        return cacheRoot(vaultPath: vaultPath) + "/" + hash
    }

    /// Audit log file path.
    /// `~/Library/Application Support/SecondBrainMCP/<vault-hash>/audit.log`
    static func auditLog(vaultPath: String) -> String {
        root(vaultPath: vaultPath) + "/audit.log"
    }

    /// Extraction lock file path (prevents concurrent cache builds).
    /// `~/Library/Application Support/SecondBrainMCP/<vault-hash>/extraction.lock`
    static func extractionLock(vaultPath: String) -> String {
        root(vaultPath: vaultPath) + "/extraction.lock"
    }

    /// Ensure the data root directory exists.
    static func ensureRootExists(vaultPath: String) {
        try? FileManager.default.createDirectory(
            atPath: root(vaultPath: vaultPath),
            withIntermediateDirectories: true
        )
    }

    /// Ensure the cache root directory exists.
    static func ensureCacheRootExists(vaultPath: String) {
        try? FileManager.default.createDirectory(
            atPath: cacheRoot(vaultPath: vaultPath),
            withIntermediateDirectories: true
        )
    }

    /// SHA256 hash of a string (first 16 bytes as hex).
    private static func hashPath(_ path: String) -> String {
        let data = Data(path.utf8)
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Migration

    /// Migrate all internal data from old in-vault location to ~/Library/Application Support/.
    /// Moves cache, deletes iCloud conflict duplicates (" 2", " 3" suffixes), and cleans up.
    static func migrateFromVaultIfNeeded(vaultPath: String) {
        let oldRoot = vaultPath + "/.secondbrain-mcp"
        guard FileManager.default.fileExists(atPath: oldRoot) else { return }

        let fm = FileManager.default
        ensureRootExists(vaultPath: vaultPath)
        ensureCacheRootExists(vaultPath: vaultPath)

        // Migrate audit.log
        let oldAuditLog = oldRoot + "/audit.log"
        let newAuditLog = auditLog(vaultPath: vaultPath)
        if fm.fileExists(atPath: oldAuditLog) && !fm.fileExists(atPath: newAuditLog) {
            try? fm.moveItem(atPath: oldAuditLog, toPath: newAuditLog)
        }

        // Migrate cache directories
        let oldCacheRoot = oldRoot + "/cache/references"
        if fm.fileExists(atPath: oldCacheRoot) {
            let newCacheRoot = cacheRoot(vaultPath: vaultPath)

            // Check if new location already has content
            let newAlreadyPopulated: Bool
            if let contents = try? fm.contentsOfDirectory(atPath: newCacheRoot), !contents.isEmpty {
                newAlreadyPopulated = true
            } else {
                newAlreadyPopulated = false
            }

            if let entries = try? fm.contentsOfDirectory(atPath: oldCacheRoot) {
                var movedCount = 0
                var deletedOrphans = 0

                for entry in entries {
                    let oldPath = oldCacheRoot + "/" + entry

                    // Delete iCloud conflict duplicates (contain " 2", " 3", etc.)
                    if entry.range(of: #" \d+$"#, options: .regularExpression) != nil {
                        try? fm.removeItem(atPath: oldPath)
                        deletedOrphans += 1
                        continue
                    }

                    // Move legitimate cache dirs to new location
                    if !newAlreadyPopulated {
                        let newPath = newCacheRoot + "/" + entry
                        if !fm.fileExists(atPath: newPath) {
                            try? fm.moveItem(atPath: oldPath, toPath: newPath)
                            movedCount += 1
                        } else {
                            try? fm.removeItem(atPath: oldPath)
                        }
                    } else {
                        try? fm.removeItem(atPath: oldPath)
                    }
                }

                if movedCount > 0 || deletedOrphans > 0 {
                    fputs("SecondBrainMCP: migrated data to ~/Library/Application Support/ — " +
                          "moved \(movedCount) cache dirs, deleted \(deletedOrphans) iCloud conflict duplicates\n", stderr)
                }
            }

            // Remove old cache directory structure
            try? fm.removeItem(atPath: oldCacheRoot)
            let oldCacheDir = oldRoot + "/cache"
            if let remaining = try? fm.contentsOfDirectory(atPath: oldCacheDir), remaining.isEmpty {
                try? fm.removeItem(atPath: oldCacheDir)
            }
        }

        // Remove old lock file
        try? fm.removeItem(atPath: oldRoot + "/extraction.lock")

        // Remove .secondbrain-mcp/ entirely if empty
        if let remaining = try? fm.contentsOfDirectory(atPath: oldRoot), remaining.isEmpty {
            try? fm.removeItem(atPath: oldRoot)
            fputs("SecondBrainMCP: removed empty .secondbrain-mcp/ from vault\n", stderr)
        }
    }
}
