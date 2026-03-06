import Foundation

/// Immutable configuration parsed from CLI arguments at startup.
/// Sendable because it's shared across actor boundaries after init.
struct ServerConfig: Sendable {
    let vaultPath: String
    let readOnly: Bool
    let allowedExtensions: Set<String>
    let logLevel: LogLevel
    let mode: OperationMode

    enum LogLevel: String, Sendable {
        case debug, info, warning, error
    }

    /// The binary operates in two modes:
    /// - `.server`: normal MCP server via StdioTransport (default)
    /// - `.extractBatch`: short-lived subprocess that extracts PDF pages, returns text via stdout pipe
    enum OperationMode: Sendable {
        case server
        case extractBatch(ExtractBatchConfig)
    }

    struct ExtractBatchConfig: Sendable {
        let vaultPath: String
        let pdfRelativePath: String  // single PDF, e.g. "references/book.pdf"
        let startPage: Int           // 1-indexed, inclusive
        let endPage: Int             // 1-indexed, inclusive
    }

    enum ConfigError: Error, CustomStringConvertible {
        case missingVaultPath
        case vaultNotFound(String)
        case vaultNotDirectory(String)
        case missingPDFPath

        var description: String {
            switch self {
            case .missingVaultPath:
                return "Missing required argument: --vault <path>"
            case .vaultNotFound(let path):
                return "Vault path does not exist: \(path)"
            case .vaultNotDirectory(let path):
                return "Vault path is not a directory: \(path)"
            case .missingPDFPath:
                return "Missing required argument for --extract-batch: --pdf-path <path>"
            }
        }
    }

    /// Parse CLI arguments into a validated config.
    /// Fails fast with a clear error if required args are missing or invalid.
    static func parse(arguments: [String]) throws -> ServerConfig {
        // Skip the first argument (executable path)
        let args = Array(arguments.dropFirst())

        var vaultPath: String?
        var readOnly = false
        var extensions: Set<String> = ["md", "markdown"]
        var logLevel: LogLevel = .info
        var extractBatch = false
        var pdfPath: String?
        var startPage = 1
        var endPage = Int.max

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--vault":
                i += 1
                guard i < args.count else {
                    throw ConfigError.missingVaultPath
                }
                vaultPath = args[i]

            case "--read-only":
                readOnly = true

            case "--extensions":
                i += 1
                if i < args.count {
                    extensions = Set(
                        args[i]
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    )
                }

            case "--log-level":
                i += 1
                if i < args.count, let level = LogLevel(rawValue: args[i].lowercased()) {
                    logLevel = level
                }

            case "--extract-batch":
                extractBatch = true

            case "--pdf-path":
                i += 1
                if i < args.count { pdfPath = args[i] }

            case "--start-page":
                i += 1
                if i < args.count, let n = Int(args[i]) { startPage = n }

            case "--end-page":
                i += 1
                if i < args.count, let n = Int(args[i]) { endPage = n }

            default:
                // Unknown flags are silently ignored.
                // This is intentional — forward compatibility with future flags.
                break
            }
            i += 1
        }

        guard let vault = vaultPath else {
            throw ConfigError.missingVaultPath
        }

        // Resolve to absolute path and validate existence
        let resolvedPath = (vault as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            throw ConfigError.vaultNotFound(resolvedPath)
        }

        guard isDirectory.boolValue else {
            throw ConfigError.vaultNotDirectory(resolvedPath)
        }

        let mode: OperationMode
        if extractBatch {
            guard let pdf = pdfPath else {
                throw ConfigError.missingPDFPath
            }
            mode = .extractBatch(ExtractBatchConfig(
                vaultPath: resolvedPath,
                pdfRelativePath: pdf,
                startPage: startPage,
                endPage: endPage
            ))
        } else {
            mode = .server
        }

        return ServerConfig(
            vaultPath: resolvedPath,
            readOnly: readOnly,
            allowedExtensions: extensions,
            logLevel: logLevel,
            mode: mode
        )
    }
}
