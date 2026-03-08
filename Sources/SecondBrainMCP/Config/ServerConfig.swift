import Foundation

/// Immutable configuration parsed from CLI arguments at startup.
/// Sendable because it's shared across actor boundaries after init.
struct ServerConfig: Sendable {
    let vaultPath: String
    let readOnly: Bool
    let allowedExtensions: Set<String>
    let logLevel: LogLevel

    enum LogLevel: String, Sendable {
        case debug, info, warning, error
    }

    enum ConfigError: Error, CustomStringConvertible {
        case missingVaultPath
        case vaultNotFound(String)
        case vaultNotDirectory(String)

        var description: String {
            switch self {
            case .missingVaultPath:
                return "Missing required argument: --vault <path>"
            case .vaultNotFound(let path):
                return "Vault path does not exist: \(path)"
            case .vaultNotDirectory(let path):
                return "Vault path is not a directory: \(path)"
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

        return ServerConfig(
            vaultPath: resolvedPath,
            readOnly: readOnly,
            allowedExtensions: extensions,
            logLevel: logLevel
        )
    }
}
