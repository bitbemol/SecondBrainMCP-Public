import Foundation

// SecondBrainMCP — Local MCP server for Markdown vault + PDF reference library
// stdout is reserved for JSON-RPC (StdioTransport). All output goes to stderr.

// Ignore SIGPIPE so broken-pipe writes return EPIPE instead of killing the process.
// Without this, when Claude Desktop closes the stdin/stdout pipes (on conversation end,
// sleep, etc.), the server gets silently terminated by the default SIGPIPE handler.
signal(SIGPIPE, SIG_IGN)

func log(_ message: String) {
    fputs("SecondBrainMCP: \(message)\n", stderr)
}

do {
    // 1. Parse CLI arguments into config
    let config = try ServerConfig.parse(arguments: CommandLine.arguments)

    log("vault: \(config.vaultPath)")
    log("read-only: \(config.readOnly)")
    log("extensions: \(config.allowedExtensions.sorted().joined(separator: ", "))")

    // 2. Ensure vault is a git repository (init or snapshot)
    let gitManager = GitManager(repoPath: config.vaultPath)
    try await gitManager.ensureRepository()
    log("git: repository ready")

    // 3. Start MCP server (blocks until client disconnects)
    try await MCPServerSetup.start(config: config, gitManager: gitManager)

} catch {
    log("fatal: \(error)")
    exit(1)
}
