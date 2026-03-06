import Foundation

/// Validates and resolves file paths, ensuring they never escape the vault root.
/// Stateless — all methods are static, pure functions. No data race concerns.
struct PathValidator {

    enum PathError: Error, CustomStringConvertible {
        case emptyPath
        case absolutePathNotAllowed(String)
        case pathEscapesRoot(String)
        case invalidExtension(String, allowed: Set<String>)
        case pathContainsTraversal(String)

        var description: String {
            switch self {
            case .emptyPath:
                return "Path must not be empty"
            case .absolutePathNotAllowed(let path):
                return "Absolute paths are not allowed: \(path)"
            case .pathEscapesRoot(let path):
                return "Path escapes vault root: \(path)"
            case .invalidExtension(let path, let allowed):
                return "File extension not allowed for '\(path)'. Allowed: \(allowed.sorted().joined(separator: ", "))"
            case .pathContainsTraversal(let path):
                return "Path contains directory traversal: \(path)"
            }
        }
    }

    /// Resolve a relative path against the vault root and validate it stays within bounds.
    ///
    /// Steps:
    /// 1. Reject empty paths and absolute paths
    /// 2. Pre-screen for obvious traversal patterns (before filesystem access)
    /// 3. Construct the full path: root + relativePath
    /// 4. Resolve symlinks and canonicalize
    /// 5. Assert the resolved path starts with the resolved root
    ///
    /// Returns the canonicalized absolute path.
    static func resolve(
        relativePath: String,
        root: String,
        allowedExtensions: Set<String>? = nil
    ) throws -> String {
        // 1. Reject empty paths
        guard !relativePath.isEmpty else {
            throw PathError.emptyPath
        }

        // 2. Reject absolute paths — callers must provide relative paths
        guard !relativePath.hasPrefix("/") else {
            throw PathError.absolutePathNotAllowed(relativePath)
        }

        // 3. Pre-screen: reject paths with traversal patterns before touching the filesystem.
        //    This catches URL-encoded and Unicode tricks that might survive canonicalization.
        let decodedPath = relativePath.removingPercentEncoding ?? relativePath
        let normalizedForCheck = decodedPath.precomposedStringWithCanonicalMapping

        if containsTraversal(normalizedForCheck) {
            throw PathError.pathContainsTraversal(relativePath)
        }

        // 4. Construct full path and resolve symlinks
        let rootURL = URL(fileURLWithPath: root).standardized
        let fullURL = rootURL.appendingPathComponent(relativePath).standardized
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let resolvedFull = fullURL.resolvingSymlinksInPath().path

        // 5. Assert containment — the resolved path must start with the resolved root.
        //    We append "/" to the root to prevent prefix attacks:
        //    "/vault-evil" starts with "/vault" but not "/vault/"
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedFull.hasPrefix(rootPrefix) || resolvedFull == resolvedRoot else {
            throw PathError.pathEscapesRoot(relativePath)
        }

        // 6. Post-resolution traversal check — belt and suspenders
        if containsTraversal(resolvedFull) {
            throw PathError.pathEscapesRoot(relativePath)
        }

        // 7. Extension allowlist (if provided)
        if let allowed = allowedExtensions, !allowed.isEmpty {
            let ext = (resolvedFull as NSString).pathExtension.lowercased()
            guard allowed.contains(ext) else {
                throw PathError.invalidExtension(relativePath, allowed: allowed)
            }
        }

        return resolvedFull
    }

    /// Check if a path string contains directory traversal patterns.
    private static func containsTraversal(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for component in components {
            if component == ".." {
                return true
            }
            // Check for sneaky Unicode dots (e.g., fullwidth period U+FF0E)
            let stripped = component.trimmingCharacters(in: .whitespaces)
            if stripped == ".." {
                return true
            }
        }
        return false
    }
}
